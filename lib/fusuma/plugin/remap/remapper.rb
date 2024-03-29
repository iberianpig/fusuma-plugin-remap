require "revdev"
require "msgpack"
require "set"
require_relative "layer_manager"

require_relative "ruinput_device_patched"

module Fusuma
  module Plugin
    module Remap
      class Remapper
        include Revdev

        VIRTUAL_KEYBOARD_NAME = "fusuma_virtual_keyboard"

        # @param layer_manager [Fusuma::Plugin::Remap::LayerManager]
        # @param keyboard_writer [IO]
        # @param source_keyboards [Array<Revdev::Device>]
        # @param internal_touchpad [Revdev::Device]
        def initialize(layer_manager:, keyboard_writer:, source_keyboards:, internal_touchpad:)
          @layer_manager = layer_manager # request to change layer
          @keyboard_writer = keyboard_writer # write event to original keyboard
          @source_keyboards = source_keyboards # original keyboard
          @internal_touchpad = internal_touchpad # internal touchpad
        end

        def run
          create_virtual_keyboard
          set_trap
          set_emergency_ungrab_keybinds("RIGHTCTRL", "LEFTCTRL")
          grab_keyboards

          old_ie = nil
          next_mapping = nil
          current_mapping = {}

          loop do
            ios = IO.select([*@source_keyboards.map(&:file), @layer_manager.reader])
            io = ios.first.first

            if io == @layer_manager.reader
              @layer_manager.receive_layer

              MultiLogger.debug "Remapper#run: layer changed to #{@layer_manager.current_layer}"
              next_mapping = @layer_manager.find_mapping
              MultiLogger.debug "Remapper#run: next_mapping: #{next_mapping}"
              next
            end

            if next_mapping && virtual_keyboard_all_key_released?
              if current_mapping != next_mapping
                current_mapping = next_mapping
              end
              next_mapping = nil
            end

            input_event = @source_keyboards.find { |kbd| kbd.file == io }.read_input_event
            input_key = find_key_from_code(input_event.code)

            if input_event.type == EV_KEY
              @emergency_stop.call(old_ie, input_event)

              old_ie = input_event
              if input_event.value != 2 # repeat
                packed = {key: input_key, status: input_event.value}.to_msgpack
                @keyboard_writer.puts(packed)
              end
            end

            remapped = current_mapping.fetch(input_key.to_sym, nil)
            if remapped.nil?
              uinput.write_input_event(input_event)
              next
            end

            remapped_event = InputEvent.new(nil, input_event.type, find_code_from_key(remapped), input_event.value)

            # Workaround to solve the problem that the remapped key remains pressed
            # when the key pressed before remapping is released after remapping
            unless record_virtual_keyboard_event?(remapped, remapped_event.value)
              # set original key before remapping
              remapped_event.code = input_event.code
            end

            # remap to command will be nil
            # e.g) remap: { X: { command: echo 'foo' } }
            # this is because the command will be executed by fusuma process
            next if remapped_event.code.nil?

            uinput.write_input_event(remapped_event)
          end
        rescue Errno::ENODEV => e # device is removed
          MultiLogger.error e.message
        rescue EOFError => e # device is closed
          MultiLogger.error e.message
        ensure
          @destroy.call
        end

        private

        def uinput
          @uinput ||= RuinputDevicePatched.new "/dev/uinput"
        end

        def pressed_virtual_keys
          @pressed_virtual_keys ||= Set.new
        end

        # record virtual keyboard event
        # @param [String] remapped_value remapped key name
        # @param [Integer] event_value event value
        # @return [Boolean] false if the key was pressed before remapping started and was released
        # @return [Boolean] true if the key was not pressed before remapping started
        def record_virtual_keyboard_event?(remapped_value, event_value)
          case event_value
          when 0
            pressed_virtual_keys.delete?(remapped_value)
          when 1
            pressed_virtual_keys.add?(remapped_value)
            true # Always return true because the remapped key may be the same
          else
            # 2 is repeat
            true
          end
        end

        def virtual_keyboard_all_key_released?
          pressed_virtual_keys.empty?
        end

        def create_virtual_keyboard
          MultiLogger.info "Create virtual keyboard: #{VIRTUAL_KEYBOARD_NAME}"

          uinput.create VIRTUAL_KEYBOARD_NAME,
            Revdev::InputId.new(
              # recognized as an internal keyboard on libinput,
              # touchpad is disabled when typing
              # see: (https://wayland.freedesktop.org/libinput/doc/latest/palm-detection.html#disable-while-typing)
              {
                bustype: Revdev::BUS_I8042,
                vendor: @internal_touchpad.device_id.vendor,
                product: @internal_touchpad.device_id.product,
                version: @internal_touchpad.device_id.version
              }
            )
        end

        def grab_keyboards
          @source_keyboards.each do |keyboard|
            wait_release_all_keys(keyboard)
            begin
              keyboard.grab
              MultiLogger.info "Grabbed #{keyboard.device_name}"
            rescue Errno::EBUSY
              MultiLogger.error "Failed to grab #{keyboard.device_name}"
            end
          end
        end

        def set_trap
          @destroy = lambda do
            @source_keyboards.each do |kbd|
              kbd.ungrab
              MultiLogger.info "Ungrabbed #{kbd.device_name}"
            rescue Errno::EINVAL
            rescue Errno::ENODEV
              # already ungrabbed
            end

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

        # Emergency stop keybind for virtual keyboard
        def set_emergency_ungrab_keybinds(first_key, second_key)
          first_keycode = find_code_from_key(first_key)
          second_keycode = find_code_from_key(second_key)
          MultiLogger.info "Emergency ungrab keybind: #{first_key} + #{second_key}"

          @emergency_stop = lambda do |prev, current|
            if (prev&.code == first_keycode && prev.value != 0) && (current.code == second_keycode && current.value != 0)
              MultiLogger.info "Emergency ungrab keybind: #{first_key} + #{second_key}"
              @destroy.call
            end
          end
        end

        # Find remappable key from mapping and return remapped key code
        # If not found, return original key code
        # If the key is found but its value is not valid, return nil
        # @example
        #  find_remapped_code({ "A" => "b" }, 30) # => 48
        #  find_remapped_code({ "A" => "b" }, 100) # => 100
        #  find_remapped_code({ "A" => {command: 'echo foobar'}  }, 30) # => nil
        #
        # @param [Hash] mapping
        # @param [Integer] code
        # @return [Integer, nil]
        def find_remapped_code(mapping, code)
          key = find_key_from_code(code) # key = "A"
          remapped_key = mapping.fetch(key.to_sym, nil) # remapped_key = "b"
          return code unless remapped_key # return original code if key is not found

          find_code_from_key(remapped_key) # remapped_code = 48
        end

        # Find key name from key code
        # @example
        #  find_key_from_code(30) # => "A"
        #  find_key_from_code(48) # => "B"
        # @param [Integer] code
        # @return [String]
        def find_key_from_code(code)
          # { 30 => :A, 48 => :B, ... }
          @keys_per_code ||= Revdev.constants.select { |c| c.start_with? "KEY_" }.map { |c| [Revdev.const_get(c), c.to_s.delete_prefix("KEY_")] }.to_h
          @keys_per_code[code]
        end

        # Find key code from key name (e.g. "A", "B", "BTN_LEFT")
        # If key name is not found, return nil
        # @example
        #  find_code_from_key("A") # => 30
        #  find_code_from_key("B") # => 48
        #  find_code_from_key("BTN_LEFT") # => 272
        #  find_code_from_key("NOT_FOUND") # => nil
        # @param [String] key
        # @return [Integer] when key is available
        # @return [nil] when key is not available
        def find_code_from_key(key)
          # { KEY_A => 30, KEY_B => 48, ... }
          @codes_per_key ||= Revdev.constants.select { |c| c.start_with?("KEY_", "BTN_") }.map { |c| [c, Revdev.const_get(c)] }.to_h

          case key
          when String
            if key.start_with?("BTN_")
              @codes_per_key[key.upcase.to_sym]
            else
              @codes_per_key["KEY_#{key}".upcase.to_sym]
            end
          when Integer
            @codes_per_key["KEY_#{key}".upcase.to_sym]
          end
        end

        def released_all_keys?(device)
          # key status if all bytes are 0, the key is not pressed
          bytes = device.read_ioctl_with(Revdev::EVIOCGKEY)
          bytes.unpack("C*").all? { |byte| byte == 0 }
        end

        def wait_release_all_keys(device, &block)
          loop do
            if released_all_keys?(device)
              break true
            else
              # wait until all keys are released
              device.read_input_event
            end
          end
        end
      end
    end
  end
end
