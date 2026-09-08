require "revdev"
require "json"
require "set"

require_relative "uinput_touchpad"
require_relative "device_selector"
require_relative "scroll_channel"
require_relative "two_finger_scroll_emulator"
require "fusuma/device"

module Fusuma
  module Plugin
    module Remap
      class TouchpadRemapper
        include Revdev

        VIRTUAL_TOUCHPAD_NAME = "fusuma_virtual_touchpad"

        # @param fusuma_writer [IO]
        # @param source_touchpads [Revdev::Device]
        # @param touchpad_name_patterns [Array, String, nil] patterns for touchpad device names (for reconnection)
        # @param pointer_scroll_enabled [Boolean]
        # @param scroll_channel [Fusuma::Plugin::Remap::ScrollChannel, nil]
        def initialize(
          fusuma_writer:,
          source_touchpads:,
          touchpad_name_patterns: nil,
          pointer_scroll_enabled: false,
          scroll_channel: nil,
          uinput_factory: nil,
          emulator_factory: nil
        )
          @source_touchpads = source_touchpads # original touchpad
          @fusuma_writer = fusuma_writer # write event to fusuma_input
          @touchpad_name_patterns = touchpad_name_patterns # for reconnection
          @pointer_scroll_requested = pointer_scroll_enabled
          @pointer_scroll_enabled = pointer_scroll_enabled
          @scroll_channel = pointer_scroll_enabled ? (scroll_channel || ScrollChannel.instance) : scroll_channel
          @uinput_factory = uinput_factory || -> { UinputTouchpad.new "/dev/uinput" }
          @emulator_factory = emulator_factory || ->(device) { TwoFingerScrollEmulator.new(device: device) }
          @uinputs_by_touchpad = {}
          @emulators_by_touchpad = {}
          @grabbed_touchpads = []

          @palm_detectors = @source_touchpads.each_with_object({}) do |source_touchpad, palm_detectors|
            palm_detectors[source_touchpad] = PalmDetection.new(source_touchpad)
          end

          set_trap
          setup_pointer_scroll_forwarding if @pointer_scroll_enabled
        end

        def run
          # stdout is block-buffered when piped (e.g. to journald) and this
          # process logs rarely; flush per write so logs appear immediately
          $stdout.sync = true

          create_virtual_touchpad

          touch_state = {}
          mt_slot = 0
          finger_state = nil

          prev_valid_touch = false
          prev_status = nil
          loop do
            ios = IO.select(selectable_ios)
            readable_ios = ios&.first || []

            if pointer_scroll_enabled? && readable_ios.include?(@scroll_channel.reader)
              read_scroll_channel
              next
            end

            io = readable_ios.first

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
            forward_touchpad_event(touchpad, input_event)

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
              when Revdev::ABS_X, Revdev::ABS_Y,
                Revdev::ABS_MT_PRESSURE,
                Revdev::ABS_MT_TOOL_TYPE,
                Revdev::ABS_MT_TOUCH_MAJOR,
                Revdev::ABS_MT_TOUCH_MINOR,
                Revdev::ABS_MT_ORIENTATION,
                Revdev::ABS_PRESSURE
                # ignore
              else
                MultiLogger.warn "unhandled event: #{input_event.hr_type}, #{input_event.hr_code}, #{input_event.value}"
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
                raise "unhandled event: #{input_event.hr_type}, #{input_event.hr_code}, #{input_event.value}"
              end
            else
              raise "unhandled event: #{input_event.hr_type}, #{input_event.hr_code}, #{input_event.value}"
            end

            # TODO:
            # Remember the most recent valid touch position and exclude it if it is close to that position
            # For example, when dragging, it is possible to touch around the edge of the touchpad again after reaching the edge of the touchpad, so in that case, you do not want to execute palm detection
            if touch_state[mt_slot][:valid_touch_point] != true
              touch_state[mt_slot][:valid_touch_point] = @palm_detectors[touchpad].palm?(touch_state[mt_slot])
            end

            if syn_report
              # Whether any slot is valid (touching)
              valid_touch = touch_state.any? { |_, st| st[:valid_touch_point] }

              status =
                if valid_touch
                  prev_valid_touch ? "update" : "begin"
                else
                  prev_valid_touch ? "end" : "cancelled"
                end

              if status == prev_status
                next
              end

              # TODO: define format as fusuma_input
              # TODO: Add data to identify multiple touchpads
              data = {
                finger: finger_state,
                status: status
              }
              @fusuma_writer.puts(data.to_json)
              prev_status = status
              prev_valid_touch = valid_touch
            end
          rescue Errno::ENODEV => e
            MultiLogger.error "Touchpad device is removed: #{e.message}"
            MultiLogger.info "Waiting for touchpad to reconnect..."
            reload_touchpads
            touch_state = {}
            mt_slot = 0
            finger_state = nil
            prev_valid_touch = false
            prev_status = nil
            retry
          end
        rescue IOError => e
          MultiLogger.error "Touchpad IO error: #{e.message}"
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
          if pointer_scroll_enabled?
            @source_touchpads.each do |source_touchpad|
              uinput_for(source_touchpad).create_from_device(name: VIRTUAL_TOUCHPAD_NAME, device: source_touchpad)
            end
          else
            # NOTE: Use uinput to create a virtual touchpad that copies from first touchpad
            uinput.create_from_device(name: VIRTUAL_TOUCHPAD_NAME, device: @source_touchpads.first)
          end
        end

        # Reload touchpads after device disconnection
        # This method waits until a touchpad is reconnected
        def reload_touchpads
          destroy_virtual_touchpads
          ungrab_touchpads
          @uinput = nil
          @uinputs_by_touchpad = {}
          @emulators_by_touchpad = {}
          @grabbed_touchpads = []

          # Wait and detect touchpad using DeviceSelector
          @source_touchpads = DeviceSelector.new(
            name_patterns: @touchpad_name_patterns,
            device_type: :touchpad
          ).select(wait: true)

          # Reinitialize palm detectors
          @palm_detectors = @source_touchpads.each_with_object({}) do |source_touchpad, palm_detectors|
            palm_detectors[source_touchpad] = PalmDetection.new(source_touchpad)
          end

          @pointer_scroll_enabled = @pointer_scroll_requested
          setup_pointer_scroll_forwarding if @pointer_scroll_enabled

          # Recreate virtual touchpad
          create_virtual_touchpad

          MultiLogger.info "Touchpad reconnected: #{@source_touchpads}"
        end

        def set_trap
          @destroy = lambda do |status = nil|
            destroy_virtual_touchpads
            ungrab_touchpads
            exit status unless status.nil?
          end

          Signal.trap(:INT) { @destroy.call(0) }
          Signal.trap(:TERM) { @destroy.call(0) }
        end

        def pointer_scroll_enabled?
          @pointer_scroll_enabled == true
        end

        def setup_pointer_scroll_forwarding
          @scroll_channel ||= ScrollChannel.instance
          grab_touchpads_for_forwarding
          return unless pointer_scroll_enabled?

          @source_touchpads.each do |source_touchpad|
            emulator_for(source_touchpad)
          end
        end

        def grab_touchpads_for_forwarding
          @source_touchpads.each do |source_touchpad|
            source_touchpad.grab
            @grabbed_touchpads << source_touchpad
          end
        rescue Errno::EBUSY => e
          MultiLogger.warn "Failed to grab touchpad for pointer scroll forwarding: #{e.message}"
          ungrab_touchpads
          @pointer_scroll_enabled = false
          @scroll_channel = nil
          @emulators_by_touchpad = {}
        end

        def selectable_ios
          ios = @source_touchpads.map(&:file)
          ios.unshift(@scroll_channel.reader) if pointer_scroll_enabled?
          ios
        end

        def read_scroll_channel
          enabled = @scroll_channel.receive
          MultiLogger.debug("TouchpadRemapper#read_scroll_channel: #{enabled.inspect}")
          return if enabled.nil?

          @emulators_by_touchpad.each do |touchpad, emulator|
            write_forwarded_events(touchpad, emulator.set_scroll_mode(enabled))
          end
        end

        def forward_touchpad_event(touchpad, input_event)
          return unless pointer_scroll_enabled?

          write_forwarded_events(touchpad, emulator_for(touchpad).process(input_event))
        end

        def write_forwarded_events(touchpad, events)
          uinput_device = uinput_for(touchpad)
          events.each { |event| uinput_device.write_input_event(event) }
        end

        def uinput_for(touchpad)
          @uinputs_by_touchpad[touchpad] ||= @uinput_factory.call
        end

        def emulator_for(touchpad)
          @emulators_by_touchpad[touchpad] ||= @emulator_factory.call(touchpad)
        end

        def destroy_virtual_touchpads
          if @uinputs_by_touchpad&.any?
            @uinputs_by_touchpad.each_value do |uinput_device|
              uinput_device.destroy
            rescue IOError
              # already destroyed
            end
          else
            begin
              uinput.destroy
            rescue IOError
              # already destroyed
            end
          end
        end

        def ungrab_touchpads
          @grabbed_touchpads.each do |touchpad|
            touchpad.ungrab
          rescue Errno::EINVAL, Errno::ENODEV
            # already ungrabbed or removed
          end
          @grabbed_touchpads = []
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
