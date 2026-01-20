require "fusuma/config"
require "msgpack"

module Fusuma
  module Plugin
    module Remap
      # Set layer sent from pipe
      class LayerManager
        require "singleton"
        include Singleton

        # Priority order for context types (higher number = higher priority)
        CONTEXT_PRIORITIES = {
          device: 1,
          thumbsense: 2,
          application: 3
        }.freeze

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
            MultiLogger.debug "Remove layer: #{layer}"
            @current_layer.delete_if { |k, _v| layer.key?(k) }
          else
            MultiLogger.debug "Add layer: #{layer}"
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

        # Find merged mapping from all applicable layers
        # Merges mappings from default, individual contexts, and complete match
        # Higher priority contexts override lower priority ones
        # @param [Hash] layer current active layer (e.g., { thumbsense: true, application: "Google-chrome" })
        # @return [Hash] merged remap mapping
        def find_merged_mapping(layer)
          @merged_layers ||= {}
          @merged_layers[layer] ||= merge_all_applicable_mappings(layer)
        end

        private

        def merge_all_applicable_mappings(layer)
          mappings = []

          # 1. default (no context) - priority 0
          default_mapping = find_mapping_for_context({})
          mappings << [0, default_mapping] if default_mapping

          # 2. Each single context key's mapping
          layer.each do |key, value|
            single_context = {key => value}
            mapping = find_mapping_for_context(single_context)
            if mapping
              priority = CONTEXT_PRIORITIES.fetch(key, 1)
              mappings << [priority, mapping]
            end
          end

          # 3. Complete match (multiple keys) - highest priority
          if layer.keys.size > 1
            complete_mapping = find_mapping_for_context(layer)
            mappings << [100, complete_mapping] if complete_mapping
          end

          # Merge in priority order (lower priority first, higher priority overwrites)
          mappings.sort_by(&:first).reduce({}) { |merged, (_, m)| merged.merge(m) }
        end

        def find_mapping_for_context(context)
          result = nil
          Fusuma::Config::Searcher.with_context(context) do
            result = Fusuma::Config.search(Fusuma::Config::Index.new(:remap))
            next unless result

            result = result.deep_transform_keys { |key| key.upcase.to_sym }
          end
          result
        end
      end
    end
  end
end
