# frozen_string_literal: true

require "fusuma/device"
require_relative "../remap/touchpad_remapper"
# require_relative "../remap/layer_manager"

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

        attr_reader :pid

        def initialize
          super
          setup_remapper
        end

        def io
          @touchpad_reader
        end

        # @return [Record]
        def read_from_io
          @unpacker ||= MessagePack::Unpacker.new(io)
          data = @unpacker.unpack

          raise "data is not Hash : #{data}" unless data.is_a? Hash

          gesture = "touch"
          finger = data["finger"]
          status = case data["status"]
          when 0
            "end"
          when 1
            "begin"
            # when 2 # TODO: support update
            #   "update"
          end

          Events::Records::GestureRecord.new(status: status, gesture: gesture, finger: finger, delta: nil)
        end

        private

        def setup_remapper
          internal_touchpad = TouchpadSelector.new(config_params(:touchpad_name_patterns)).select.first
          if internal_touchpad.nil?
            MultiLogger.error("No touchpad found: #{config_params(:touchpad_name_patterns)}")
            exit
          end

          MultiLogger.info("set up remapper")
          MultiLogger.info("internal_touchpad: #{internal_touchpad.device_name}")

          # layer_manager = Remap::LayerManager.instance

          # physical touchpad input event
          @touchpad_reader, touchpad_writer = IO.pipe

          @pid = fork do
            # layer_manager.writer.close
            @touchpad_reader.close
            remapper = Remap::TouchpadRemapper.new(
              # layer_manager: layer_manager,
              touchpad_writer: touchpad_writer,
              source_touchpad: internal_touchpad
            )
            remapper.run
          end
          # layer_manager.reader.close
          touchpad_writer.close
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
