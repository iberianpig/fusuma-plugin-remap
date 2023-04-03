# frozen_string_literal: true

require "fusuma/plugin/remap/layer_manager"

module Fusuma
  module Plugin
    module Inputs
      # Get keyboard events from remapper
      class RemapKeyboardInput < Input
        def config_param_types
          {
            keyboard_name_patterns: [Array, String]
          }
        end

        attr_reader :pid

        def initialize
          super
          layer_manager = Remap::LayerManager.instance

          # physical keyboard input event
          @keyboard_reader, keyboard_writer = IO.pipe

          source_keyboards = KeyboardSelector.new(config_params(:keyboard_name_patterns)).select

          @pid = fork do
            layer_manager.writer.close
            @keyboard_reader.close
            remapper = Remap::Remapper.new(
              layer_manager: layer_manager,
              source_keyboards: source_keyboards,
              keyboard_writer: keyboard_writer
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
          def initialize(names)
            @names = names
          end

          # @return [Array<Fusuma::Device>]
          def select
            if @names
              Fusuma::Device.all.select do |d|
                Array(config_params(:keyboard_name_patterns)).any? do |name|
                  d.name =~ name
                end
              end
            else
              Fusuma::Device.all.select { |d| d.capabilities =~ /keyboard/ }
            end
          end
        end
      end
    end
  end
end
