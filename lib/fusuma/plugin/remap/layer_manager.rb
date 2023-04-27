require "fusuma/config"
require "msgpack"

module Fusuma
  module Plugin
    module Remap
      # Set layer sent from pipe
      class LayerManager
        require "singleton"
        include Singleton
        attr_reader :reader, :writer

        def initialize
          @layers = {}
          @reader, @writer = IO.pipe
          @current_layer = {} # preserve order
        end

        # @param [Hash] layer
        # @param [Boolean] remove
        def send_layer(layer:, remove: false)
          return if @last_layer == layer && @last_remove == remove

          @last_layer = layer
          @last_remove = remove
          @writer.puts({layer: layer, remove: remove}.to_msgpack)
        end

        # Read layer from pipe and return remap layer
        # @example
        # @return [Hash]
        def receive_layer
          @layer_unpacker ||= MessagePack::Unpacker.new(@reader)

          data = @layer_unpacker.unpack

          return unless data.is_a? Hash

          data = data.deep_symbolize_keys
          layer = data[:layer] # e.g { thumbsense: true }
          remove = data[:remove] # e.g true

          if remove
            @current_layer.delete_if { |k, _v| layer.key?(k) }
          else
            # If duplicate keys exist, order of keys is preserved
            @current_layer.merge!(layer)
          end
        end

        # Find remap layer from config
        # @param [Hash] layer
        # @return [Hash]
        def find_mapping(layer = @current_layer)
          @layers[layer] ||= begin
            result = nil
            _ = Fusuma::Config::Searcher.find_context(layer) {
              result = Fusuma::Config.search(Fusuma::Config::Index.new(:remap))
              next unless result

              result = result.deep_transform_keys do |key|
                key.upcase.to_sym
              end
            }

            result || {}
          end
        end
      end
    end
  end
end
