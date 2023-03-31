module Fusuma
  module Plugin
    module Remap
      class Layer
        require 'singleton'
        include Singleton
        attr_reader :reader, :writer

        def initialize
          @reader, @writer = IO.pipe
        end

        # Write layer name to pipe
        # @param [symbol] name
        def add(context_name)
          @writer.puts(context_name)
        end
      end
    end
  end
end
