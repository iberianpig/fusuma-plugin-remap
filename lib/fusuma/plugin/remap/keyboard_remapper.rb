require "revdev"
require "msgpack"
require "set"
require_relative "layer_manager"
require_relative "uinput_keyboard"
require_relative "device_selector"
require_relative "device_matcher"
require_relative "modifier_state"
require "fusuma/device"

module Fusuma
  module Plugin
    module Remap
      class KeyboardRemapper
        include Revdev

        VIRTUAL_KEYBOARD_NAME = "fusuma_virtual_keyboard"
        DEFAULT_EMERGENCY_KEYBIND = "RIGHTCTRL+LEFTCTRL".freeze
        DEVICE_CHECK_INTERVAL = 3 # seconds - interval for checking new devices

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
          @device_matcher = DeviceMatcher.new
          @device_mappings = {}
        end

        def run
          create_virtual_keyboard
          @source_keyboards = reload_keyboards

          # Manage modifier key states
          @modifier_state = ModifierState.new

          old_ie = nil
          layer = nil
          current_mapping = {}

          loop do
            ios = IO.select(
              [*@source_keyboards.map(&:file), @layer_manager.reader],
              nil,
              nil,
              DEVICE_CHECK_INTERVAL
            )

            # Timeout - check for new devices
            if ios.nil?
              check_and_add_new_devices
              next
            end

            readable_ios = ios.first

            # Prioritize layer changes over keyboard events to ensure
            # layer state is updated before processing key inputs
            io = if readable_ios.include?(@layer_manager.reader)
              @layer_manager.reader
            else
              readable_ios.first
            end

            if io == @layer_manager.reader
              layer = @layer_manager.receive_layer # update @current_layer
              if layer.nil?
                next
              end

              # Clear mapping caches when layer changes
              @device_mappings = {}
              @separated_mappings_cache = {}
              @layer_changed = true
              next
            end

            source_keyboard = @source_keyboards.find { |kbd| kbd.file == io }
            input_event = source_keyboard.read_input_event

            # Skip non-keyboard events (EV_REL, EV_ABS, etc.) - pass through as-is
            # This prevents code collision issues (e.g., KEY_ESC=1 vs REL_Y=1)
            if should_skip_non_key_event?(input_event.type)
              write_event_with_log(input_event, context: "passthrough (non-key event)")
              next
            end

            current_device_name = source_keyboard.device_name

            # Get device-specific mapping
            device_mapping = get_mapping_for_device(current_device_name, layer || {})

            # Wait until all virtual keys are released before applying new mapping
            if @layer_changed && virtual_keyboard_all_key_released?
              @layer_changed = false
            end

            # Use device-specific mapping (wait during layer change to prevent key stuck)
            current_mapping = @layer_changed ? current_mapping : device_mapping

            # Separate mapping into simple remap and combo remap
            # This prevents double conversion in key swap scenarios (e.g., LEFTALT <-> LEFTMETA)
            simple_mapping, combo_mapping = get_separated_mappings(current_mapping)

            input_key = code_to_key(input_event.code)

            # Apply simple key-to-key remapping first (modmap-style)
            # e.g., CAPSLOCK -> LEFTCTRL, so modifier state tracks the remapped key
            effective_key = apply_simple_remap(simple_mapping, input_key)

            if input_event.type == EV_KEY
              @emergency_stop.call(old_ie, input_event)

              old_ie = input_event

              @modifier_state.update(effective_key, input_event.value)

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

            remapped, is_modifier_remap = find_remapping(combo_mapping, effective_key)
            case remapped
            when String, Symbol
              # Continue to key output processing below
            when Array
              # Output sequence: e.g., [LEFTSHIFT+HOME, DELETE]
              if input_event.value == 1
                execute_modifier_remap(remapped, input_event)
              end
              next
            when Hash
              # Command execution (e.g., {:SENDKEY=>"LEFTCTRL+BTN_LEFT", :CLEARMODIFIERS=>true})
              # Skip input event processing and let Fusuma's Executor handle this
              next
            when nil
              if effective_key != input_key
                # Output simple-remapped key (e.g., CAPSLOCK -> LEFTCTRL)
                remapped_code = key_to_code(effective_key)
                if remapped_code
                  remapped_event = InputEvent.new(nil, input_event.type, remapped_code, input_event.value)
                  update_virtual_key_state(effective_key, remapped_event.value)
                  write_event_with_log(remapped_event, context: "simple remap from #{input_key}")
                else
                  write_event_with_log(input_event, context: "simple remap failed")
                end
              else
                write_event_with_log(input_event, context: "passthrough")
              end
              next
            else
              MultiLogger.warn("Invalid remapped value - type: #{remapped.class}, key: #{input_key}")
              next
            end

            # For modifier remaps, handle specially:
            # Release currently pressed modifiers → Send remapped key → Re-press modifiers
            if is_modifier_remap && input_event.value == 1
              execute_modifier_remap(remapped, input_event)
              next
            end

            # Handle key combination output (e.g., "LEFTALT+LEFT")
            # If remapped value contains "+", it's a key combination that needs special handling
            if remapped.to_s.include?("+")
              if input_event.value == 1 # only on key press
                send_key_combination(remapped, input_event.type)
              end
              next
            end

            remapped_code = key_to_code(remapped)
            if remapped_code.nil?
              MultiLogger.warn("Invalid remapped value - unknown key: #{remapped}, input: #{input_key}")
              write_event_with_log(input_event, context: "remap failed")
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

            write_event_with_log(remapped_event, context: "remapped from #{input_key}")
          rescue Errno::ENODEV => e # device is removed
            MultiLogger.error "Device is removed: #{e.message}"
            @device_mappings = {} # Clear cache for new device configuration
            @separated_mappings_cache = {}
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

        # Get mapping for specific device from cache or LayerManager
        # @param device_name [String] Physical device name
        # @param layer [Hash] Layer information
        # @return [Hash] Mapping for the device
        def get_mapping_for_device(device_name, layer)
          matched_pattern = @device_matcher.match(device_name)
          effective_layer = matched_pattern ? layer.merge(device: matched_pattern) : layer
          cache_key = [device_name, layer].hash
          @device_mappings[cache_key] ||= @layer_manager.find_merged_mapping(effective_layer)
        end

        # Check for newly connected devices and add them to source_keyboards
        # Called periodically via IO.select timeout
        def check_and_add_new_devices
          current_device_paths = @source_keyboards.map { |kbd| kbd.file.path }

          selector = KeyboardSelector.new(@config[:keyboard_name_patterns])
          available_devices = selector.try_open_devices

          new_devices = available_devices.reject do |device|
            current_device_paths.include?(device.file.path)
          end

          # Close devices that are already in source_keyboards to avoid duplicate file handles
          available_devices.each do |device|
            device.file.close if current_device_paths.include?(device.file.path)
          end

          return if new_devices.empty?

          MultiLogger.info("New keyboard(s) detected: #{new_devices.map(&:device_name)}")

          grabbed_devices = []
          new_devices.each do |device|
            wait_release_all_keys(device)
            device.grab
            MultiLogger.info "Grabbed keyboard: #{device.device_name}"
            grabbed_devices << device
          rescue Errno::EBUSY
            MultiLogger.error "Failed to grab keyboard: #{device.device_name}"
          rescue Errno::ENODEV
            MultiLogger.warn "Device removed during grab: #{device.device_name}"
          end

          return if grabbed_devices.empty?

          @source_keyboards.concat(grabbed_devices)
          @device_mappings = {} # Clear cache for new device configuration
          @separated_mappings_cache = {}
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
          # Use DeviceSelector without wait - keyboard remap should work even without touchpad
          internal_touchpad = DeviceSelector.new(
            name_patterns: touchpad_name_patterns,
            device_type: :touchpad
          ).select(wait: false).first

          MultiLogger.info "Create virtual keyboard: #{VIRTUAL_KEYBOARD_NAME}"

          if internal_touchpad.nil?
            MultiLogger.warn("No touchpad found: #{touchpad_name_patterns}")
            MultiLogger.warn("Disable-while-typing feature will not work without a touchpad")
            # Create virtual keyboard without touchpad device ID
            # disable-while-typing will not work in this case
            uinput_keyboard.create VIRTUAL_KEYBOARD_NAME
          else
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
            if prev&.code == first_keycode && prev.value != 0 && current.code == second_keycode && current.value != 0
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

        # Check if the event should skip remap processing (non-keyboard events)
        # EV_REL (mouse/trackpoint movement) and EV_ABS (touchpad absolute position)
        # should be passed through without remapping to avoid code collision issues
        # (e.g., KEY_ESC=1 vs REL_Y=1)
        # @param event_type [Integer] input event type (EV_KEY, EV_REL, EV_ABS, etc.)
        # @return [Boolean] true if the event should be passed through without remapping
        def should_skip_non_key_event?(event_type)
          event_type != EV_KEY
        end

        # Separate mapping into "simple remap" and "combo remap"
        # This prevents double conversion in key swap scenarios (e.g., LEFTALT <-> LEFTMETA)
        #
        # Classification rules:
        # - simple_remap: key doesn't contain "+", value is String/Symbol without "+"
        #   e.g., CAPSLOCK: "LEFTCTRL", LEFTALT: "LEFTMETA"
        #
        # - combo_remap: key contains "+" OR value is Array/Hash OR value contains "+"
        #   e.g., "LEFTCTRL+A": "HOME", A: ["B", "C"], X: { command: "echo" }
        #
        # @param mapping [Hash] original mapping
        # @return [Array<Hash, Hash>] [simple_remap, combo_remap]
        def separate_mappings(mapping)
          simple_remap = {}
          combo_remap = {}

          mapping.each do |key, value|
            key_str = key.to_s
            value_str = value.to_s if value.is_a?(String) || value.is_a?(Symbol)

            if key_str.include?("+")
              combo_remap[key] = value
            elsif value.is_a?(Array) || value.is_a?(Hash) || value_str&.include?("+")
              combo_remap[key] = value
            else
              simple_remap[key] = value
            end
          end

          [simple_remap, combo_remap]
        end

        # Get separated mappings from cache or separate and cache
        # @param mapping [Hash] original mapping
        # @return [Array<Hash, Hash>] [simple_remap, combo_remap]
        def get_separated_mappings(mapping)
          @separated_mappings_cache ||= {}
          @separated_mappings_cache[mapping.hash] ||= separate_mappings(mapping)
        end

        # Apply simple key-to-key remapping (modmap-style)
        # - Returns remapped key if simple remap exists
        # - Skips combinations (containing "+"), Arrays, and Hashes
        # - Returns original key if no match
        #
        # @param mapping [Hash] remapping configuration
        # @param key [String] input key name
        # @return [String] remapped key or original key
        def apply_simple_remap(mapping, key)
          remapped = mapping.fetch(key.to_sym, nil)
          if remapped.is_a?(String) && !remapped.include?("+")
            remapped
          else
            key
          end
        end

        # Search for remapping
        # If modifier keys are pressed, first search with modifier+key
        #
        # @param mapping [Hash] remapping configuration
        # @param input_key [String] input key name
        # @return [Array] [remapped key, is modifier remap]
        def find_remapping(mapping, input_key)
          # If modifier keys are pressed, first search with modifier+key (e.g., "LEFTCTRL+A")
          if @modifier_state&.pressed_modifiers&.any?
            combined_key = @modifier_state.current_combination(input_key)
            remapped = mapping.fetch(combined_key.to_sym, nil)
            if remapped
              # For modifier key remapping (e.g., LEFTMETA: LEFTALT), set is_modifier_remap to false
              # This distinguishes it from modifier+key combinations (e.g., LEFTCTRL+A: HOME)
              # Modifier key itself should be remapped directly without execute_modifier_remap
              is_modifier_remap = !@modifier_state.modifier?(input_key)
              return [remapped.is_a?(Array) ? remapped : remapped.to_s, is_modifier_remap]
            end
          end

          # If not found, search with simple key (e.g., "A")
          remapped = mapping.fetch(input_key.to_sym, nil)
          # If remapped is an Array (output sequence), return as is
          result = remapped.is_a?(Array) ? remapped : remapped&.to_s
          [result, false]
        end

        # Execute remapping with modifier keys
        # @param remapped [String, Array] remapped key (single or array)
        # @param input_event [InputEvent] original input event
        #
        # === Output sequence support ===
        # If remapped is an Array, send each element in order
        # e.g., ["LEFTSHIFT+HOME", "DELETE"]
        #      → Shift+Home (press/release) → Delete (press/release)
        def execute_modifier_remap(remapped, input_event)
          # 1. Temporarily release currently pressed modifier keys
          release_current_modifiers

          # 2. Send remapped key(s) (press + release)
          # === Output sequence support ===
          send_key_combination(remapped, input_event.type)

          # 3. Re-press modifier keys
          restore_current_modifiers
        end

        # Release currently pressed modifier keys
        def release_current_modifiers
          return unless @modifier_state

          @modifier_state.pressed_modifiers.each do |modifier_key|
            code = key_to_code(modifier_key)
            next unless code

            release_event = InputEvent.new(nil, EV_KEY, code, 0)
            write_event_with_log(release_event, context: "modifier release")
          end
        end

        # Re-press modifier keys
        def restore_current_modifiers
          return unless @modifier_state

          @modifier_state.pressed_modifiers.each do |modifier_key|
            code = key_to_code(modifier_key)
            next unless code

            press_event = InputEvent.new(nil, EV_KEY, code, 1)
            write_event_with_log(press_event, context: "modifier restore")
          end
        end

        # Send a key combination (e.g., "LEFTCTRL+O" → press Ctrl, press O, release O, release Ctrl)
        # @param key_input [String, Array] Key string or array
        #   - String: Single key combination (e.g., "Q", "LEFTCTRL+O")
        #   - Array: Output sequence (e.g., ["LEFTSHIFT+HOME", "DELETE"])
        # @param event_type [Integer] Event type
        # @return [void]
        #
        # === Output sequence support ===
        # If Array, send each element in order
        def send_key_combination(key_input, event_type)
          # If Array, send each element in order
          if key_input.is_a?(Array)
            key_input.each { |key| send_key_combination(key.to_s, event_type) }
            return
          end

          keys = key_input.to_s.split("+")

          # Press all keys
          keys.each do |key|
            code = key_to_code(key)
            next unless code

            press_event = InputEvent.new(nil, event_type, code, 1)
            write_event_with_log(press_event, context: "combination")
          end

          # Release all keys in reverse order
          keys.reverse.each do |key|
            code = key_to_code(key)
            next unless code

            release_event = InputEvent.new(nil, event_type, code, 0)
            write_event_with_log(release_event, context: "combination")
          end
        end

        # Convert key event value to state string
        # @param value [Integer] 0=released, 1=pressed, 2=repeat
        # @return [String]
        def value_to_state(value)
          case value
          when 0 then "released"
          when 1 then "pressed"
          when 2 then "repeat"
          else "unknown(#{value})"
          end
        end

        # Write input event with debug logging
        # @param event [InputEvent] event to send
        # @param context [String, nil] additional context info
        def write_event_with_log(event, context: nil)
          if event.type == EV_KEY
            key = code_to_key(event.code)
            state = value_to_state(event.value)
            msg = "[REMAP] #{key} #{state}"
            msg += " (#{context})" if context
            MultiLogger.debug(msg)
          end

          uinput_keyboard.write_input_event(event)
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
            logged_no_device = false
            loop do
              keyboards = try_open_devices

              if keyboards.empty?
                unless logged_no_device
                  MultiLogger.warn "No keyboard found: #{@names}"
                  logged_no_device = true
                end

                wait_for_device
              else
                return keyboards
              end
            end
          end

          def try_open_devices
            Fusuma::Device.reset # reset cache to get the latest device information
            devices = Fusuma::Device.all.select do |d|
              next if d.name == VIRTUAL_KEYBOARD_NAME

              Array(@names).any? { |name| d.name =~ /#{name}/ }
            end

            devices.filter_map do |d|
              Revdev::EventDevice.new("/dev/input/#{d.id}")
            rescue Errno::ENOENT, Errno::ENODEV, Errno::EACCES => e
              MultiLogger.warn "Failed to open #{d.name} (/dev/input/#{d.id}): #{e.message}"
              nil
            end
          end

          private

          def wait_for_device
            sleep 3
          end
        end
      end
    end
  end
end
