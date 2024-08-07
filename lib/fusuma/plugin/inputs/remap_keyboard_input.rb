# frozen_string_literal: true

require "fusuma/device"
require_relative "../remap/keyboard_remapper"
require_relative "../remap/layer_manager"

module Fusuma
  module Plugin
    module Inputs
      # Get keyboard events from remapper
      class RemapKeyboardInput < Input
        include CustomProcess

        def config_param_types
          {
            keyboard_name_patterns: [Array, String],
            touchpad_name_patterns: [Array, String]
          }
        end

        def initialize
          super
          setup_remapper
        end

        def io
          @fusuma_reader
        end

        # override Input#read_from_io
        # @return [Record]
        def read_from_io
          @unpacker ||= MessagePack::Unpacker.new(io)
          data = @unpacker.unpack

          raise "data is not Hash : #{data}" unless data.is_a? Hash

          status = (data["status"] == 1) ? "pressed" : "released"
          Events::Records::KeypressRecord.new(status: status, code: data["key"], layer: data["layer"])
        rescue EOFError => e
          MultiLogger.error "#{self.class.name}: #{e}"
          MultiLogger.error "Shutdown fusuma process..."
          Process.kill("TERM", Process.pid)
        end

        private

        def setup_remapper
          config = {

            keyboard_name_patterns: config_params(:keyboard_name_patterns),
            touchpad_name_patterns: config_params(:touchpad_name_patterns)
          }

          layer_manager = Remap::LayerManager.instance

          # physical keyboard input event
          @fusuma_reader, fusuma_writer = IO.pipe

          fork do
            layer_manager.writer.close
            @fusuma_reader.close
            remapper = Remap::KeyboardRemapper.new(
              layer_manager: layer_manager,
              fusuma_writer: fusuma_writer,
              config: config
            )
            remapper.run
          end
          layer_manager.reader.close
          fusuma_writer.close
        end
      end
    end
  end
end
