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

        # @param touchpad_writer [IO]
        # @param source_touchpad [Revdev::Device]
        def initialize(touchpad_writer:, source_touchpad:)
          @source_touchpad = source_touchpad # original touchpad
          @touchpad = touchpad_writer # write event to fusuma_input
        end

        # TODO: grab touchpad events and remap them
        #       send remapped events to virtual touchpad or virtual mouse
        def run
          create_virtual_touchpad
          loop do
            IO.select([@source_touchpad.file]) # , @layer_manager.reader])

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
            input_event = @source_touchpad.read_input_event

            @touch_state ||= {}
            @mt_slot ||= 0
            @touch_state[@mt_slot] ||= {
              MT_TRACKING_ID: nil,
              X: nil,
              Y: nil,
              valid_touch_point: false
            }
            @finger_state ||= nil
            @syn_report = nil
            @button_touch ||= nil

            case input_event.type
            when Revdev::EV_ABS
              case input_event.code
              when Revdev::ABS_MT_SLOT
                @mt_slot = input_event.value
                @touch_state[@mt_slot] ||= {}
              when Revdev::ABS_MT_TRACKING_ID
                @touch_state[@mt_slot][:MT_TRACKING_ID] = input_event.value
                if input_event.value == -1
                  @touch_state[@mt_slot] = {}
                end
              when Revdev::ABS_MT_POSITION_X
                @touch_state[@mt_slot][:X] = input_event.value
              when Revdev::ABS_MT_POSITION_Y
                @touch_state[@mt_slot][:Y] = input_event.value
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
                @finger_state = (input_event.value == 1) ? 1 : nil
              when Revdev::BTN_TOOL_DOUBLETAP
                @finger_state = (input_event.value == 1) ? 2 : nil
              when Revdev::BTN_TOOL_TRIPLETAP
                @finger_state = (input_event.value == 1) ? 3 : nil
              when Revdev::BTN_TOOL_QUADTAP
                @finger_state = (input_event.value == 1) ? 4 : nil
              when 0x148 # define BTN_TOOL_QUINTTAP	0x148	/* Five fingers on trackpad */
                @finger_state = (input_event.value == 1) ? 5 : nil
              end
            when Revdev::EV_MSC
              case input_event.code
              when 0x05 # define MSC_TIMESTAMP		0x05
                @current_timestamp = input_event.value
              end
            when Revdev::EV_SYN
              case input_event.code
              when Revdev::SYN_REPORT
                @syn_report = input_event.value
              else
                raise "unhandled event"
              end
            else
              pp [input_event.hr_type, input_event.hr_code, input_event.value]
              raise "unhandled event"
            end

            # TODO: This is Thumbsense specific logic, so it should be moved to Thumbsense plugin
            # Disable 20% of the touch area on the left and right edges of the touchpad.
            # Prevents the cursor from moving left and right when the left and right edges of the touchpad are touched.
            if @touch_state[@mt_slot][:valid_touch_point] != true && (@touch_state[@mt_slot][:X] && @touch_state[@mt_slot][:Y])
              @touch_state[@mt_slot][:valid_touch_point] =
                if @touch_state[@mt_slot][:Y] > 0.8 * @source_touchpad.absinfo_for_axis(Revdev::ABS_MT_POSITION_Y)[:absmax]
                  true
                else
                  !(@touch_state[@mt_slot][:X] < 0.2 * @source_touchpad.absinfo_for_axis(Revdev::ABS_MT_POSITION_X)[:absmax] \
                  || @touch_state[@mt_slot][:X] > 0.8 * @source_touchpad.absinfo_for_axis(Revdev::ABS_MT_POSITION_X)[:absmax] \
                  || @touch_state[@mt_slot][:Y] < 0.2 * @source_touchpad.absinfo_for_axis(Revdev::ABS_MT_POSITION_Y)[:absmax])
                end
            end

            if @syn_report
              @syn_report = nil

              # TODO: refactor Thumbsense specific logic: Event suppression
              @status = if @touch_state.any? { |k, v| v[:valid_touch_point] }
                1
              else
                0
              end

              # TODO: send begin/update/end events
              # Send events only when status changes from 0 to 1 or from 1 to 0
              if @status != @prev_status
                @prev_status = @status
                # input plugin needs to write a line (including newline) to the pipe, so use puts
                @touchpad.puts({status: @status, finger: @finger_state, touch_state: @touch_state}.to_msgpack)
              end
            end
          end
        end

        private

        def uinput
          @uinput ||= UinputTouchpad.new "/dev/uinput"
        end

        def create_virtual_touchpad
          MultiLogger.info "Create virtual keyboard: #{VIRTUAL_TOUCHPAD_NAME}"

          uinput.create_from_device(name: VIRTUAL_TOUCHPAD_NAME, device: @source_touchpad)
        end
      end
    end
  end
end
