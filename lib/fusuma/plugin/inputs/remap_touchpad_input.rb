# frozen_string_literal: true

require_relative "../remap/touchpad_remapper"

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
          source_touchpads = TouchpadSelector.new(config_params(:touchpad_name_patterns)).select
          if source_touchpads.empty?
            MultiLogger.error("No touchpad found: #{config_params(:touchpad_name_patterns)}")
            exit
          end

          MultiLogger.info("set up remapper")
          MultiLogger.info("touchpad: #{source_touchpads}")

          # layer_manager = Remap::LayerManager.instance

          # physical touchpad input event
          @fusuma_reader, fusuma_writer = IO.pipe

          fork do
            # layer_manager.writer.close
            @fusuma_reader.close
            remapper = Remap::TouchpadRemapper.new(
              # layer_manager: layer_manager,
              fusuma_writer: fusuma_writer,
              source_touchpads: source_touchpads
            )
            remapper.run
          end
          # layer_manager.reader.close
          fusuma_writer.close
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
