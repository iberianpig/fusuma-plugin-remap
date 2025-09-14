require "revdev"
require "msgpack"
require "set"
require_relative "layer_manager"
require_relative "uinput_keyboard"
require "fusuma/device"

module Fusuma
  module Plugin
    module Remap
      class KeyboardRemapper
        include Revdev

        VIRTUAL_KEYBOARD_NAME = "fusuma_virtual_keyboard"
        DEFAULT_EMERGENCY_KEYBIND = "RIGHTCTRL+LEFTCTRL".freeze

        # Key conversion tables for better performance and readability
        KEYMAP = Revdev.constants.select { |c| c.start_with?("KEY_", "BTN_") }
          .map { |c| [Revdev.const_get(c), c.to_s.delete_prefix("KEY_")] }
          .to_h.freeze
        CODEMAP = Revdev.constants.select { |c| c.start_with?("KEY_", "BTN_") }
          .map { |c| [c, Revdev.const_get(c)] }
          .to_h.freeze

        # @param layer_manager [Fusuma::Plugin::Remap::LayerManager]
        # @param fusuma_writer [IO]
        # @param config [Hash]
        def initialize(layer_manager:, fusuma_writer:, config: {})
          @layer_manager = layer_manager # request to change layer
          @fusuma_writer = fusuma_writer # write event to original keyboard
          @config = config
        end

        def run
          create_virtual_keyboard
          @source_keyboards = reload_keyboards

          old_ie = nil
          layer = nil
          next_mapping = nil
          current_mapping = {}

          loop do
            ios = IO.select([*@source_keyboards.map(&:file), @layer_manager.reader])
            io = ios.first.first

            if io == @layer_manager.reader
              layer = @layer_manager.receive_layer # update @current_layer
              if layer.nil?
                next
              end

              next_mapping = @layer_manager.find_mapping(layer)
              next
            end

            if next_mapping && virtual_keyboard_all_key_released?
              if current_mapping != next_mapping
                current_mapping = next_mapping
              end
              next_mapping = nil
            end

            input_event = @source_keyboards.find { |kbd| kbd.file == io }.read_input_event
            input_key = code_to_key(input_event.code)

            if input_event.type == EV_KEY
              @emergency_stop.call(old_ie, input_event)

              old_ie = input_event
              if input_event.value != 2 # repeat
                data = {key: input_key, status: input_event.value, layer: layer}
                begin
                  @fusuma_writer.write(data.to_msgpack)
                rescue IOError => e
                  MultiLogger.error("Failed to write to fusuma_writer: #{e.message}")
                  @destroy&.call(1)
                  return
                end
              end
            end

            remapped = current_mapping.fetch(input_key.to_sym, nil)
            case remapped
            when String, Symbol
              # Remapped to another key - continue processing below
            when Hash
              # Command execution (e.g., {:SENDKEY=>"LEFTCTRL+BTN_LEFT", :CLEARMODIFIERS=>true})
              # Skip input event processing and let Fusuma's Executor handle this
              next
            when nil
              # Not remapped - write original key event as-is
              uinput_keyboard.write_input_event(input_event)
              next
            else
              # Invalid remapping configuration
              MultiLogger.warn("Invalid remapped value - type: #{remapped.class}, key: #{input_key}")
              next
            end

            remapped_code = key_to_code(remapped)
            if remapped_code.nil?
              MultiLogger.warn("Invalid remapped value - unknown key: #{remapped}, input: #{input_key}")
              uinput_keyboard.write_input_event(input_event)
              next
            end

            remapped_event = InputEvent.new(nil, input_event.type, remapped_code, input_event.value)

            # Workaround: If a key was pressed before remapping started and is being released,
            # use the original key code to ensure proper key release
            if should_use_original_key?(remapped, remapped_event.value)
              remapped_event.code = input_event.code
            else
              # Only update virtual key state if we're using the remapped key
              update_virtual_key_state(remapped, remapped_event.value)
            end

            # remap to command will be nil
            # e.g) remap: { X: { command: echo 'foo' } }
            # this is because the command will be executed by fusuma process
            next if remapped_event.code.nil?

            uinput_keyboard.write_input_event(remapped_event)
          rescue Errno::ENODEV => e # device is removed
            MultiLogger.error "Device is removed: #{e.message}"
            @source_keyboards = reload_keyboards
          end
        rescue EOFError => e # device is closed
          MultiLogger.error "Device is closed: #{e.message}"
        ensure
          @destroy&.call
        end

        private

        def reload_keyboards
          source_keyboards = KeyboardSelector.new(@config[:keyboard_name_patterns]).select

          MultiLogger.info("Reload keyboards: #{source_keyboards.map(&:device_name)}")

          set_trap(source_keyboards)
          set_emergency_ungrab_keys(@config[:emergency_ungrab_keys])
          grab_keyboards(source_keyboards)
        rescue => e
          MultiLogger.error "Failed to reload keyboards: #{e.message}"
          MultiLogger.error e.backtrace.join("\n")
        end

        def uinput_keyboard
          @uinput_keyboard ||= UinputKeyboard.new("/dev/uinput")
        end

        def pressed_virtual_keys
          @pressed_virtual_keys ||= Set.new
        end

        # Update virtual keyboard key state
        # @param [String] remapped_value remapped key name
        # @param [Integer] event_value event value (0: release, 1: press, 2: repeat)
        # @return [void]
        def update_virtual_key_state(remapped_value, event_value)
          case event_value
          when 0 # key release
            pressed_virtual_keys.delete(remapped_value)
          when 1 # key press
            pressed_virtual_keys.add(remapped_value)
            # when 2 is repeat - no state change needed
          end
        end

        # Check if we should use the original key code instead of remapped key
        # This handles the case where a key was pressed before remapping started
        # and is released after remapping
        # @param [String] remapped_value remapped key name
        # @param [Integer] event_value event value (0: release, 1: press, 2: repeat)
        # @return [Boolean] true if we should use original key code
        def should_use_original_key?(remapped_value, event_value)
          case event_value
          when 0 # key release
            # If the key was not in our pressed set, it means it was pressed
            # before remapping started, so we should use original key
            !pressed_virtual_keys.include?(remapped_value)
          when 1, 2 # key press or repeat
            false # Always use remapped key for press/repeat events
          end
        end

        def virtual_keyboard_all_key_released?
          pressed_virtual_keys.empty?
        end

        def create_virtual_keyboard
          touchpad_name_patterns = @config[:touchpad_name_patterns]
          internal_touchpad = TouchpadSelector.new(touchpad_name_patterns).select.first

          if internal_touchpad.nil?
            MultiLogger.error("No touchpad found: #{touchpad_name_patterns}")
            exit
          end

          MultiLogger.info "Create virtual keyboard: #{VIRTUAL_KEYBOARD_NAME}"

          uinput_keyboard.create VIRTUAL_KEYBOARD_NAME,
            Revdev::InputId.new(
              # disable while typing is enabled when
              # - Both the keyboard and touchpad are BUS_I8042
              # - The touchpad and keyboard have the same vendor/product
              # ref: (https://wayland.freedesktop.org/libinput/doc/latest/palm-detection.html#disable-while-typing)
              #
              {
                bustype: Revdev::BUS_I8042,
                vendor: internal_touchpad.device_id.vendor,
                product: internal_touchpad.device_id.product,
                version: internal_touchpad.device_id.version
              }
            )
        end

        def grab_keyboards(keyboards)
          keyboards.each do |keyboard|
            wait_release_all_keys(keyboard)
            begin
              keyboard.grab
              MultiLogger.info "Grabbed keyboard: #{keyboard.device_name}"
            rescue Errno::EBUSY
              MultiLogger.error "Failed to grab keyboard: #{keyboard.device_name}"
            end
          end
        end

        # @param [Array<Revdev::EventDevice>] keyboards
        def set_trap(keyboards)
          @destroy = lambda do |status = 0|
            keyboards.each do |kbd|
              kbd.ungrab
            rescue Errno::EINVAL
            rescue Errno::ENODEV
              # already ungrabbed
            end

            begin
              uinput_keyboard.destroy
            rescue IOError
              # already destroyed
            end

            exit status
          end

          Signal.trap(:INT) { @destroy.call }
          Signal.trap(:TERM) { @destroy.call(1) }
        end

        # Emergency stop keybind for virtual keyboard
        def set_emergency_ungrab_keys(keybind_string)
          keybinds = keybind_string&.split("+")
          # TODO: Extract to a configuration file or make it optional
          #       it should stop other remappers
          if keybinds&.size != 2
            MultiLogger.warn "Invalid emergency ungrab keybinds: #{keybinds}, fallback to #{DEFAULT_EMERGENCY_KEYBIND}"
            MultiLogger.warn "Please set two keys separated by '+'"
            MultiLogger.warn <<~YAML
              plugin:
                inputs:
                  remap_keyboard_input:
                    emergency_ungrab_keys: RIGHTCTRL+LEFTCTRL
            YAML

            keybinds = DEFAULT_EMERGENCY_KEYBIND.split("+")
          end

          MultiLogger.info "Emergency ungrab keybind: #{keybinds[0]}+#{keybinds[1]}"

          first_keycode = key_to_code(keybinds[0])
          second_keycode = key_to_code(keybinds[1])

          @emergency_stop = lambda do |prev, current|
            if (prev&.code == first_keycode && prev.value != 0) && (current.code == second_keycode && current.value != 0)
              MultiLogger.info "Emergency ungrab keybind is pressed: #{keybinds[0]}+#{keybinds[1]}"
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
          key = code_to_key(code) # key = "A"
          remapped_key = mapping.fetch(key.to_sym, nil) # remapped_key = "b"
          return code unless remapped_key # return original code if key is not found

          key_to_code(remapped_key) # remapped_code = 48
        end

        # Find key name from key code
        # @example
        #  code_to_key(30) # => "A"
        #  code_to_key(48) # => "B"
        #  code_to_key(272) # => "BTN_LEFT"
        # @param [Integer] code
        # @return [String]
        # @return [nil] when key is not found
        def code_to_key(code)
          KEYMAP[code]
        end

        # Find key code from key name (e.g. "A", "B", "BTN_LEFT")
        # If key name is not found, return nil
        # @example
        #  key_to_code("A") # => 30
        #  key_to_code("B") # => 48
        #  key_to_code("BTN_LEFT") # => 272
        #  key_to_code("NOT_FOUND") # => nil
        # @param [String] key
        # @return [Integer] when key is available
        # @return [nil] when key is not available
        def key_to_code(key)
          case key
          when String
            if key.start_with?("BTN_")
              CODEMAP[key.upcase.to_sym]
            else
              CODEMAP["KEY_#{key}".upcase.to_sym]
            end
          when Integer
            CODEMAP["KEY_#{key}".upcase.to_sym]
          end
        end

        def released_all_keys?(device)
          # key status if all bytes are 0, the key is not pressed
          bytes = device.read_ioctl_with(Revdev::EVIOCGKEY)
          bytes.unpack("C*").all?(0)
        end

        def wait_release_all_keys(device, &block)
          loop do
            if released_all_keys?(device)
              break true
            else
              # wait until all keys are released
              begin
                device.read_input_event
              rescue Errno::ENODEV => e
                MultiLogger.warn("Device removed while waiting to release keys: #{e.message}")
                return false
              end
            end
          end
        end

        # Devices to detect key presses and releases
        class KeyboardSelector
          def initialize(names)
            @names = names
          end

          # Select devices that match the name
          # If no device is found, it will wait for 3 seconds and try again
          # @return [Array<Revdev::EventDevice>]
          def select
            displayed_no_keyboard = false
            loop do
              Fusuma::Device.reset # reset cache to get the latest device information
              devices = Fusuma::Device.all.select do |d|
                next if d.name == VIRTUAL_KEYBOARD_NAME

                Array(@names).any? { |name| d.name =~ /#{name}/ }
              end
              if devices.empty?
                unless displayed_no_keyboard
                  MultiLogger.warn "No keyboard found: #{@names}"
                  displayed_no_keyboard = true
                end
                wait_for_device

                next
              end

              return devices.map { |d| Revdev::EventDevice.new("/dev/input/#{d.id}") }
            end
          end

          def wait_for_device
            sleep 3
          end
        end

        class TouchpadSelector
          def initialize(names = nil)
            @names = names
          end

          # @return [Array<Revdev::EventDevice>]
          def select
            devices = if @names
              Fusuma::Device.all.select { |d| Array(@names).any? { |name| d.name =~ /#{name}/ } }
            else
              # available returns only touchpad devices
              Fusuma::Device.available
            end

            devices.map { |d| Revdev::EventDevice.new("/dev/input/#{d.id}") }
          end
        end
      end
    end
  end
end
