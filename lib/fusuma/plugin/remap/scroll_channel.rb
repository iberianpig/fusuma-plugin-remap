# frozen_string_literal: true

require "json"
require "singleton"

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

          @last_scroll = enabled
          @writer.write_nonblock({scroll: enabled}.to_json + "\n")
        rescue IO::WaitWritable, Errno::EAGAIN, IOError, Errno::EPIPE
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
