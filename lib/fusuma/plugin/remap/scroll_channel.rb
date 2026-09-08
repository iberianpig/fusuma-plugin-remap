# frozen_string_literal: true

require "json"
require "singleton"
require "fusuma/multi_logger"

module Fusuma
  module Plugin
    module Remap
      class ScrollChannel
        include Singleton

        attr_reader :reader, :writer

        def initialize
          @reader, @writer = IO.pipe
          @last_scroll = nil
        end

        def send_scroll(enabled)
          enabled = !!enabled
          return if @last_scroll == enabled

          previous = @last_scroll
          @last_scroll = enabled
          MultiLogger.debug("ScrollChannel#send_scroll: #{enabled}")
          @writer.write_nonblock({scroll: enabled}.to_json + "\n")
        rescue IO::WaitWritable, Errno::EAGAIN, IOError, Errno::EPIPE => e
          # Roll back so the next state change is not skipped as a duplicate
          @last_scroll = previous
          MultiLogger.warn("ScrollChannel#send_scroll failed: #{e.class}: #{e.message}")
          nil
        end

        def receive
          line = @reader.gets
          return unless line

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
