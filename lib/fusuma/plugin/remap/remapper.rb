require 'revdev'
require_relative './ruinput_device_patched'

module Fusuma
  module Plugin
    module Remap
      class Remapper
        include Revdev
        def initialize(layer_reader:, keyboard_writer:, source_keyboards:, internal_touchpad:, layers: nil)
          @layer_reader = layer_reader # request to change layer
          @keyboard_writer = keyboard_writer # write event to original keyboard
          @source_keyboards = source_keyboards # original keyboard
          @internal_touchpad = internal_touchpad # internal touchpad
          @layers = layers # remap configuration from config.yml
        end

        def run
          @uinput = RuinputDevicePatched.new '/dev/uinput'

          destroy = lambda do
            begin
              @source_keyboards.each { |kbd| kbd.ungrab }
              puts 'ungrab'
            rescue StandardError => e
              puts e.message
            end
            begin
              @uinput.destroy
              puts 'destroy'
            rescue StandardError => e
              puts e.message
            end
            exit 0
          end

          Signal.trap(:INT) { destroy.call }
          Signal.trap(:TERM) { destroy.call }

          begin
            @uinput.create 'fusuma_remapper',
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

            while true
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
          rescue StandardError => e
            puts e.message
            puts e.backtrace.join "\n\t"
          end
        end
      end
    end
  end
end
