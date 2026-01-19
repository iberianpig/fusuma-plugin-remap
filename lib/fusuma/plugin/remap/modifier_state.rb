# frozen_string_literal: true

require "set"

module Fusuma
  module Plugin
    module Remap
      # Tracks the pressed state of modifier keys
      class ModifierState
        MODIFIERS = Set.new(%w[
          LEFTCTRL RIGHTCTRL
          LEFTALT RIGHTALT
          LEFTSHIFT RIGHTSHIFT
          LEFTMETA RIGHTMETA
        ]).freeze

        def initialize
          @pressed = Set.new
        end

        def update(key, event_value)
          return unless modifier?(key)

          case event_value
          when 1 then @pressed.add(key)
          when 0 then @pressed.delete(key)
          end
        end

        def current_combination(key)
          return key if modifier?(key)

          modifiers = pressed_modifiers
          if modifiers.empty?
            key
          else
            "#{modifiers.join("+")}+#{key}"
          end
        end

        def pressed_modifiers
          @pressed.to_a.sort
        end

        def modifier?(key)
          MODIFIERS.include?(key)
        end

        def reset
          @pressed.clear
        end
      end
    end
  end
end
