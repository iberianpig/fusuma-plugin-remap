# frozen_string_literal: true

require "fusuma/plugin/remap/remapper"
require "fusuma/plugin/remap/layer_manager"

module Fusuma
  module Plugin
    module Inputs
      # Get keyboard events from remapper
      class RemapKeyboardInput < Input
        def config_param_types
          {
            keyboard_name_patterns: [Array, String],
            touchpad_name_patterns: [Array, String]
          }
        end

        attr_reader :pid

        def initialize
          super
          layer_manager = Remap::LayerManager.instance

          # physical keyboard input event
          @keyboard_reader, keyboard_writer = IO.pipe

          source_keyboards = KeyboardSelector.new(config_params(:keyboard_name_patterns)).select
          internal_touchpad = TouchpadSelector.new(config_params(:touchpad_name_patterns)).select.first

          @pid = fork do
            layer_manager.writer.close
            @keyboard_reader.close
            remapper = Remap::Remapper.new(
              layer_manager: layer_manager,
              source_keyboards: source_keyboards,
              keyboard_writer: keyboard_writer,
              internal_touchpad: internal_touchpad
            )
            remapper.run
          end
          layer_manager.reader.close
          keyboard_writer.close
        end

        def io
          @keyboard_reader
        end

        # Devices to detect key presses and releases
        class KeyboardSelector
          def initialize(names = ["keyboard", "Keyboard", "KEYBOARD"])
            @names = names
          end

          # @return [Array<Revdev::EventDevice>]
          def select
            Fusuma::Device.all.select do |d|
              Array(@names).any? do |name|
                d.name =~ /#{name}/
              end
            end.map do |d|
              device_path = "/dev/input/#{d.id}"
              ev = Revdev::EventDevice.new(device_path)
              ev
            end
          end
        end

        class TouchpadSelector
          def initialize(names)
            @names = names
          end

          # @return [Array<Revdev::EventDevice>]
          def select
            devices = if @names
              Fusuma::Device.all.select do |d|
                Array(@names).any? do |name|
                  d.name =~ /#{name}/
                end
              end
            else
              # touchpads
              Fusuma::Device.available
            end

            devices.map do |d|
              device_path = "/dev/input/#{d.id}"
              ev = Revdev::EventDevice.new(device_path)
              ev
            end
          end
        end
      end
    end
  end
end
