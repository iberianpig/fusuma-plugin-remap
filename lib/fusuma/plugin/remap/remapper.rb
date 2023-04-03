require "revdev"
require "msgpack"
require "set"
require_relative "./ruinput_device_patched"

module Fusuma
  module Plugin
    module Remap
      class Remapper
        include Revdev
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
          @uinput = RuinputDevicePatched.new "/dev/uinput"

          destroy = lambda do
            begin
              @source_keyboards.each { |kbd| kbd.ungrab }
              puts "ungrab"
            rescue => e
              puts e.message
            end
            begin
              @uinput.destroy
              puts "destroy"
            rescue => e
              puts e.message
            end
            exit 0
          end

          Signal.trap(:INT) { destroy.call }
          Signal.trap(:TERM) { destroy.call }

          begin
            @uinput.create "fusuma_remapper",
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

            sleep 1
            @source_keyboards.each do |keyboard|
              # FIXME: release all keys
              # keyboard.keys.each do |key|
              #   keyboard.write_input_event(InputEvent.new(Time.now, EV_KEY, key, 0))
              # end
              keyboard.grab
            end
            old_ie = nil

            loop do
              # FIXME: hanlde multiple keyboards
              # ios = IO.select([*@source_keyboards, @layer_reader])
              # case io = ios.first.first
              # when @source_keyboards
              #
              # else
              #
              # end
              keyboard = @source_keyboards.first
              ie = keyboard.read_input_event

              # FIXME: exit when RIGHTCTRL-LEFTCTRL is pressed
              if (old_ie&.code == KEY_RIGHTCTRL && old_ie.value != 0) && (ie.code == KEY_LEFTCTRL && ie.value != 0)
                destroy.call
              end
              old_ie = ie if ie.type == EV_KEY

              # TODO: change layer
              # layer_name = @layer_reader.gets
              layer_name = :thumbsense
              mapping = @layers[layer_name]
              remapped_key = mapping.fetch(ie.code, ie.code)

              next unless remapped_key

              remapped_event = InputEvent.new(ie.time, ie.type, remapped_key, ie.value)

              len = @uinput.write_input_event(remapped_event)
              puts "type:#{ie.hr_type}(#{ie.type})\tcode:#{ie.hr_code}(#{ie.code})\tvalue:#{ie.value} (#{len})"
            end
          rescue => e
            puts e.message
            puts e.backtrace.join "\n\t"
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
      end
    end
  end
end
