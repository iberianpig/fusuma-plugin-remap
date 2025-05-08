require "revdev"
require "msgpack"
require "set"

require_relative "uinput_touchpad"

module Fusuma
  module Plugin
    module Remap
      class TouchpadRemapper
        include Revdev

        VIRTUAL_TOUCHPAD_NAME = "fusuma_virtual_touchpad"

        # @param fusuma_writer [IO]
        # @param source_touchpads [Revdev::Device]
        def initialize(fusuma_writer:, source_touchpads:)
          @source_touchpads = source_touchpads # original touchpad
          @fusuma_writer = fusuma_writer # write event to fusuma_input

          # FIXME: PalmDetection should be initialized with each touchpad
          @palm_detectors = @source_touchpads.each_with_object({}) do |source_touchpad, palm_detectors|
            palm_detectors[source_touchpad] = PalmDetection.new(source_touchpad)
          end

          set_trap
        end

        # TODO: grab touchpad events and remap them
        #       send remapped events to virtual touchpad or virtual mouse
        def run
          create_virtual_touchpad

          touch_state = {}
          mt_slot = 0
          finger_state = nil
          loop do
            ios = IO.select(@source_touchpads.map(&:file)) # , @layer_manager.reader])
            io = ios&.first&.first

            touchpad = @source_touchpads.find { |t| t.file == io }

            ## example of input_event
            # Event: time 1698456258.380027, type 3 (EV_ABS), code 57 (ABS_MT_TRACKING_ID), value 43679
            # Event: time 1698456258.380027, type 3 (EV_ABS), code 53 (ABS_MT_POSITION_X), value 648
            # Event: time 1698456258.380027, type 3 (EV_ABS), code 54 (ABS_MT_POSITION_Y), value 209
            # Event: time 1698456258.380027, type 1 (EV_KEY), code 330 (BTN_TOUCH), value 1
            # Event: time 1698456258.380027, type 1 (EV_KEY), code 325 (BTN_TOOL_FINGER), value 1
            # Event: time 1698456258.380027, type 3 (EV_ABS), code 0 (ABS_X), value 648
            # Event: time 1698456258.380027, type 3 (EV_ABS), code 1 (ABS_Y), value 209
            # Event: time 1698456258.380027, type 4 (EV_MSC), code 5 (MSC_TIMESTAMP), value 0
            # Event: time 1698456258.380027, -------------- SYN_REPORT ------------
            # Event: time 1698456258.382693, type 3 (EV_ABS), code 47 (ABS_MT_SLOT), value 1
            # Event: time 1698456258.382693, type 3 (EV_ABS), code 57 (ABS_MT_TRACKING_ID), value 43680
            # Event: time 1698456258.382693, type 3 (EV_ABS), code 53 (ABS_MT_POSITION_X), value 400
            # Event: time 1698456258.382693, type 3 (EV_ABS), code 54 (ABS_MT_POSITION_Y), value 252
            # Event: time 1698456258.382693, type 1 (EV_KEY), code 325 (BTN_TOOL_FINGER), value 0
            # Event: time 1698456258.382693, type 1 (EV_KEY), code 333 (BTN_TOOL_DOUBLETAP), value 1
            # Event: time 1698456258.382693, type 4 (EV_MSC), code 5 (MSC_TIMESTAMP), value 7100
            # Event: time 1698456258.382693, -------------- SYN_REPORT ------------
            input_event = touchpad.read_input_event

            touch_state[mt_slot] ||= {MT_TRACKING_ID: nil, X: nil, Y: nil, valid_touch_point: false}
            syn_report = nil

            case input_event.type
            when Revdev::EV_ABS
              case input_event.code
              when Revdev::ABS_MT_SLOT
                mt_slot = input_event.value
                touch_state[mt_slot] ||= {}
              when Revdev::ABS_MT_TRACKING_ID
                touch_state[mt_slot][:MT_TRACKING_ID] = input_event.value
                if input_event.value == -1
                  touch_state[mt_slot] = {}
                end
              when Revdev::ABS_MT_POSITION_X
                touch_state[mt_slot][:X] = input_event.value
              when Revdev::ABS_MT_POSITION_Y
                touch_state[mt_slot][:Y] = input_event.value
              when Revdev::ABS_X, Revdev::ABS_Y
                # ignore
              when Revdev::ABS_MT_PRESSURE
                # ignore
              when Revdev::ABS_MT_TOOL_TYPE
                # ignore
              else
                raise "unhandled event"
              end
            when Revdev::EV_KEY
              case input_event.code
              when Revdev::BTN_TOUCH
                # ignore
              when Revdev::BTN_TOOL_FINGER
                finger_state = (input_event.value == 1) ? 1 : 0
              when Revdev::BTN_TOOL_DOUBLETAP
                finger_state = (input_event.value == 1) ? 2 : 1
              when Revdev::BTN_TOOL_TRIPLETAP
                finger_state = (input_event.value == 1) ? 3 : 2
              when Revdev::BTN_TOOL_QUADTAP
                finger_state = (input_event.value == 1) ? 4 : 3
              when 0x148 # define BTN_TOOL_QUINTTAP	0x148	/* Five fingers on trackpad */
                finger_state = (input_event.value == 1) ? 5 : 4
              end
            when Revdev::EV_MSC
              case input_event.code
              when 0x05 # define MSC_TIMESTAMP		0x05
                # ignore
                # current_timestamp = input_event.value
              end
            when Revdev::EV_SYN
              case input_event.code
              when Revdev::SYN_REPORT
                syn_report = input_event.value
              when Revdev::SYN_DROPPED
                MultiLogger.error "Dropped: #{input_event.value}"
              else
                raise "unhandled event", "#{input_event.hr_type}, #{input_event.hr_code}, #{input_event.value}"
              end
            else
              raise "unhandled event", "#{input_event.hr_type}, #{input_event.hr_code}, #{input_event.value}"
            end

            # TODO:
            # Remember the most recent valid touch position and exclude it if it is close to that position
            # For example, when dragging, it is possible to touch around the edge of the touchpad again after reaching the edge of the touchpad, so in that case, you do not want to execute palm detection
            if touch_state[mt_slot][:valid_touch_point] != true
              touch_state[mt_slot][:valid_touch_point] = @palm_detectors[touchpad].palm?(touch_state[mt_slot])
            end

            if syn_report
              # TODO: define format as fusuma_input
              # TODO: Add data to identify multiple touchpads
              data = {finger: finger_state, touch_state: touch_state}
              @fusuma_writer.write(data.to_msgpack)
            end
          end
        rescue => e
          MultiLogger.error "An error occurred: #{e.message}"
        ensure
          @destroy&.call
        end

        private

        def uinput
          @uinput ||= UinputTouchpad.new "/dev/uinput"
        end

        def create_virtual_touchpad
          MultiLogger.info "Create virtual touchpad: #{VIRTUAL_TOUCHPAD_NAME}"
          # NOTE: Use uinput to create a virtual touchpad that copies from first touchpad
          uinput.create_from_device(name: VIRTUAL_TOUCHPAD_NAME, device: @source_touchpads.first)
        end

        def set_trap
          @destroy = lambda do
            begin
              uinput.destroy
            rescue IOError
              # already destroyed
            end
            exit 0
          end

          Signal.trap(:INT) { @destroy.call }
          Signal.trap(:TERM) { @destroy.call }
        end

        # Detect palm touch
        class PalmDetection
          def initialize(touchpad)
            @max_x = touchpad.absinfo_for_axis(Revdev::ABS_MT_POSITION_X)[:absmax]
            @max_y = touchpad.absinfo_for_axis(Revdev::ABS_MT_POSITION_Y)[:absmax]
          end

          def palm?(touch_state)
            return false unless touch_state[:X] && touch_state[:Y]

            if 0.8 * @max_y < touch_state[:Y]
              true
            else
              !(
                # Disable 20% of the touch area on the left, right
                (touch_state[:X] < 0.2 * @max_x || touch_state[:X] > 0.8 * @max_x) ||
                # Disable 10% of the touch area on the top edge
                (touch_state[:Y] < 0.1 * @max_y && (touch_state[:X] < 0.2 * @max_x || touch_state[:X] > 0.8 * @max_x)
                )
              )
            end
          end
        end
      end
    end
  end
end
