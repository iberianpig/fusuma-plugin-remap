# frozen_string_literal: true

require "json"
require "singleton"

module Fusuma
  module Plugin
    module Remap
      class ScrollChannel
        include Singleton

        # Remap value that designates the pointer-scroll action instead of a key
        POINTER_SCROLL = "POINTER_SCROLL"

        # @param value [Object] a remap value from the config
        # @return [Boolean] whether it designates the pointer-scroll action
        def self.pointer_scroll_value?(value)
          (value.is_a?(String) || value.is_a?(Symbol)) && POINTER_SCROLL.casecmp?(value.to_s)
        end

        attr_reader :reader, :writer

        def initialize
          @reader, @writer = IO.pipe
          @last_scroll = nil
        end

        def send_scroll(enabled)
          enabled = !!enabled
          return if @last_scroll == enabled

          @writer.write_nonblock({scroll: enabled}.to_json + "\n")
          @last_scroll = enabled
        rescue IO::WaitWritable, Errno::EAGAIN, IOError, Errno::EPIPE
          nil
        end

        def receive
          line = @reader.gets
          return :closed unless line

          data = JSON.parse(line)
          return unless data.is_a?(Hash)

          data["scroll"]
        rescue IOError, JSON::ParserError
          nil
        end
      end
    end
  end
end
