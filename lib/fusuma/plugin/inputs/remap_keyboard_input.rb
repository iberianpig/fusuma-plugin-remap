# frozen_string_literal: true

require "json"
require_relative "../remap/keyboard_remapper"
require_relative "../remap/layer_manager"
require_relative "../remap/native_keyboard_controller"

module Fusuma
  module Plugin
    module Inputs
      # Get keyboard events from remapper
      class RemapKeyboardInput < Input
        include CustomProcess

        def config_param_types
          {
            emergency_ungrab_keys: [String],
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
          line = io.gets
          raise EOFError, "pipe closed" unless line

          data = JSON.parse(line)

          raise "data is not Hash : #{data}" unless data.is_a? Hash
          raise "unexpected native keyboard remapper message on key pipe: #{data}" unless key_event?(data)

          status = (data["status"] == 1) ? "pressed" : "released"
          Events::Records::KeypressRecord.new(status: status, code: data["key"], layer: data["layer"])
        rescue EOFError => e
          MultiLogger.error "#{self.class.name}: #{e}"
          MultiLogger.error "Shutdown fusuma process..."
          Process.kill("TERM", Process.pid)
        end

        def shutdown
          @native_controller&.shutdown
          super
        end

        private

        def key_event?(data)
          data["t"].nil? || data["t"] == "key"
        end

        def setup_remapper
          config = {
            emergency_ungrab_keys: config_params(:emergency_ungrab_keys),
            keyboard_name_patterns: config_params(:keyboard_name_patterns),
            touchpad_name_patterns: config_params(:touchpad_name_patterns)
          }

          layer_manager = Remap::LayerManager.instance

          if (binary_path = native_binary_path)
            setup_native_remapper(binary_path, layer_manager, config)
          else
            MultiLogger.warn("fusuma-remap-keyboard not found; falling back to fork remapper")
            setup_fork_remapper(layer_manager, config)
          end
        end

        def setup_native_remapper(binary_path, layer_manager, config)
          @native_controller = Remap::NativeKeyboardController.new(
            binary_path: binary_path,
            layer_manager: layer_manager,
            config: config
          )
          @fusuma_reader = @native_controller.reader
          child_pids << @native_controller.pid
        end

        def setup_fork_remapper(layer_manager, config)
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

        def native_binary_path
          candidates = [
            ENV["FUSUMA_REMAP_KEYBOARD_BIN"],
            File.expand_path("../../../../native/build/fusuma-remap-keyboard", __dir__)
          ].compact

          ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
            candidates << File.join(dir, "fusuma-remap-keyboard")
          end

          candidates.find { |path| File.file?(path) && File.executable?(path) }
        end
      end
    end
  end
end
