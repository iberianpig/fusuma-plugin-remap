# frozen_string_literal: true

require "fusuma/device"
require "fusuma/plugin/remap/remapper"
require "fusuma/plugin/remap/layer_manager"

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

        attr_reader :pid

        def initialize
          super
          setup_remapper
        end

        def io
          @keyboard_reader
        end

        # @param record [String]
        # @return [Event]
        def create_event(record:)
          data = MessagePack.unpack(record) # => {"key"=>"J", "status"=>1}

          unless data.is_a? Hash
            MultiLogger.error("Invalid record: #{record}", data: data)
            return
          end

          code = data["key"]
          status = (data["status"] == 1) ? "pressed" : "released"
          record = Events::Records::KeypressRecord.new(status: status, code: code)

          e = Events::Event.new(tag: tag, record: record)
          MultiLogger.debug(input_event: e)
          e
        end

        private

        def setup_remapper
          source_keyboards = KeyboardSelector.new(config_params(:keyboard_name_patterns)).select
          if source_keyboards.empty?
            MultiLogger.error("No keyboard found: #{config_params(:keyboard_name_patterns)}")
            exit
          end

          internal_touchpad = TouchpadSelector.new(config_params(:touchpad_name_patterns)).select.first
          if internal_touchpad.nil?
            MultiLogger.error("No touchpad found: #{config_params(:touchpad_name_patterns)}")
            exit
          end

          MultiLogger.info("set up remapper")
          MultiLogger.info("source_keyboards: #{source_keyboards.map(&:device_name)}")
          MultiLogger.info("internal_touchpad: #{internal_touchpad.device_name}")

          layer_manager = Remap::LayerManager.instance

          # physical keyboard input event
          @keyboard_reader, keyboard_writer = IO.pipe

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

        # Devices to detect key presses and releases
        class KeyboardSelector
          def initialize(names = ["keyboard", "Keyboard", "KEYBOARD"])
            @names = names
          end

          # @return [Array<Revdev::EventDevice>]
          def select
            devices = Fusuma::Device.all.select { |d| Array(@names).any? { |name| d.name =~ /#{name}/ } }
            devices.map { |d| Revdev::EventDevice.new("/dev/input/#{d.id}") }
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
