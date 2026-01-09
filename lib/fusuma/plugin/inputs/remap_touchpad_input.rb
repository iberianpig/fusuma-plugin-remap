# frozen_string_literal: true

require_relative "../remap/touchpad_remapper"
require_relative "../remap/device_selector"

module Fusuma
  module Plugin
    module Inputs
      # Get touchpad events from remapper
      class RemapTouchpadInput < Input
        include CustomProcess

        def config_param_types
          {
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

          gesture = "touch"
          finger = data["finger"]
          status = data["status"]

          Events::Records::GestureRecord.new(gesture: gesture, status: status, finger: finger, delta: nil)
        rescue EOFError => e
          MultiLogger.error "#{self.class.name}: #{e}"
          MultiLogger.error "Shutdown fusuma process..."
          Process.kill("TERM", Process.pid)
        end

        private

        def setup_remapper
          # layer_manager = Remap::LayerManager.instance

          # physical touchpad input event
          @fusuma_reader, fusuma_writer = IO.pipe
          touchpad_name_patterns = config_params(:touchpad_name_patterns)

          fork do
            # layer_manager.writer.close
            @fusuma_reader.close

            # DeviceSelector waits until touchpad is found (like KeyboardSelector)
            # NOTE: This must be inside fork to avoid blocking the main Fusuma process
            source_touchpads = Remap::DeviceSelector.new(
              name_patterns: touchpad_name_patterns,
              device_type: :touchpad
            ).select(wait: true)

            MultiLogger.info("set up remapper")
            MultiLogger.info("touchpad: #{source_touchpads}")

            remapper = Remap::TouchpadRemapper.new(
              # layer_manager: layer_manager,
              fusuma_writer: fusuma_writer,
              source_touchpads: source_touchpads,
              touchpad_name_patterns: touchpad_name_patterns
            )
            remapper.run
          end
          # layer_manager.reader.close
          fusuma_writer.close
        end
      end
    end
  end
end
