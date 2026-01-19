# frozen_string_literal: true

require "fusuma/config"

module Fusuma
  module Plugin
    module Remap
      # Matches device names against device patterns defined in config
      class DeviceMatcher
        def initialize
          @patterns = nil
        end

        # Find matching device pattern for a device name
        # @param device_name [String] physical device name (e.g., "PFU HHKB-Hybrid")
        # @return [String, nil] matched pattern (e.g., "HHKB"), or nil if no match
        def match(device_name)
          return nil if device_name.nil?

          patterns.find { |pattern| device_name =~ /#{pattern}/i }
        end

        private

        # Collect device patterns from config (cached)
        # @return [Array<String>] device patterns (e.g., ["HHKB", "AT Translated"])
        def patterns
          @patterns ||= collect_patterns
        end

        # Collect unique device patterns from all context sections in keymap
        def collect_patterns
          keymap = Config.instance.keymap
          return [] unless keymap.is_a?(Array)

          keymap.filter_map { |section| section.dig(:context, :device) }.uniq
        end
      end
    end
  end
end
