require "fusuma/config"
require "msgpack"

module Fusuma
  module Plugin
    module Remap
      # Set layer sent from pipe
      class LayerManager
        require "singleton"
        include Singleton
        attr_reader :reader, :writer, :current_layer, :layers

        def initialize
          @layers = {}
          @reader, @writer = IO.pipe
          @current_layer = {} # preserve order
          @last_layer = nil
          @last_remove = nil
        end

        # @param [Hash] layer
        # @param [Boolean] remove
        def send_layer(layer:, remove: false)
          return if (@last_layer == layer) && (@last_remove == remove)

          @last_layer = layer
          @last_remove = remove
          @writer.write({layer: layer, remove: remove}.to_msgpack)
        end

        # Read layer from pipe and update @current_layer
        # @return [Hash] current layer
        # @example
        #  receive_layer
        #  # => { thumbsense: true }
        #  receive_layer
        #  # => { thumbsense: true, application: "Google-chrome" }
        def receive_layer
          @layer_unpacker ||= MessagePack::Unpacker.new(@reader)

          data = @layer_unpacker.unpack

          return unless data.is_a? Hash

          data = data.deep_symbolize_keys
          layer = data[:layer] # e.g { thumbsense: true }
          remove = data[:remove] # e.g true

          # update @current_layer
          if remove
            @current_layer.delete_if { |k, _v| layer.key?(k) }
          else
            # If duplicate keys exist, order of keys is preserved
            @current_layer.merge!(layer)
          end
          @current_layer
        end

        # Find remap layer from config
        # @param [Hash] layer
        # @return [Hash] remap layer
        def find_mapping(layer)
          @layers[layer] ||= begin
            result = nil
            _ = Fusuma::Config::Searcher.find_context(layer) do
              result = Fusuma::Config.search(Fusuma::Config::Index.new(:remap))
              next unless result

              result = result.deep_transform_keys { |key| key.upcase.to_sym }
            end

            result || {}
          end
        end
      end
    end
  end
end
