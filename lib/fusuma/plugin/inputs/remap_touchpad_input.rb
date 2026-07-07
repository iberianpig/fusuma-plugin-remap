# frozen_string_literal: true

require "json"
require_relative "../remap/touchpad_remapper"
require_relative "../remap/device_selector"
require_relative "../remap/scroll_channel"

module Fusuma
  module Plugin
    module Inputs
      # Get touchpad events from remapper
      class RemapTouchpadInput < Input
        include CustomProcess

        POINTER_SCROLL = "POINTER_SCROLL"

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
          line = io.gets
          raise EOFError, "pipe closed" unless line

          data = JSON.parse(line)

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
          scroll_channel = Remap::ScrollChannel.instance
          pointer_scroll_enabled = pointer_scroll_configured?

          # physical touchpad input event
          @fusuma_reader, fusuma_writer = IO.pipe
          touchpad_name_patterns = config_params(:touchpad_name_patterns)

          fork do
            # layer_manager.writer.close
            scroll_channel.writer.close
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
              fusuma_writer: fusuma_writer,
              source_touchpads: source_touchpads,
              touchpad_name_patterns: touchpad_name_patterns,
              pointer_scroll_enabled: pointer_scroll_enabled,
              scroll_channel: scroll_channel
            )
            remapper.run
          end
          fusuma_writer.close
        end

        def pointer_scroll_configured?
          keymap = Fusuma::Config.instance.keymap
          Array(keymap).any? do |section|
            remap = section[:remap] || section["remap"]
            contains_pointer_scroll?(remap)
          end
        rescue
          false
        end

        def contains_pointer_scroll?(value)
          case value
          when Hash
            value.values.any? { |nested| contains_pointer_scroll?(nested) }
          when Array
            value.any? { |nested| contains_pointer_scroll?(nested) }
          when String, Symbol
            value.to_s.upcase == POINTER_SCROLL
          else
            false
          end
        end
      end
    end
  end
end
