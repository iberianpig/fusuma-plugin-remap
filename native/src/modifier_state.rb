# frozen_string_literal: true

class ModifierState
  MODIFIERS = {
    "LEFTCTRL" => 1,
    "RIGHTCTRL" => 1,
    "LEFTALT" => 1,
    "RIGHTALT" => 1,
    "LEFTSHIFT" => 1,
    "RIGHTSHIFT" => 1,
    "LEFTMETA" => 1,
    "RIGHTMETA" => 1
  }.freeze

  def initialize
    @pressed = {"LEFTCTRL" => 1}
    @pressed.delete("LEFTCTRL")
  end

  def update(key, event_value)
    return unless modifier?(key)

    if event_value == 1
      @pressed[key] = 1
    elsif event_value == 0
      @pressed.delete(key)
    end
  end

  def current_combination(key)
    return key if modifier?(key)

    modifiers = pressed_modifiers
    if modifiers.empty?
      key
    else
      modifiers.join("+") + "+" + key
    end
  end

  def pressed_modifiers
    @pressed.keys.sort
  end

  def modifier?(key)
    MODIFIERS[key] == 1
  end

  def reset
    @pressed = {"LEFTCTRL" => 1}
    @pressed.delete("LEFTCTRL")
  end
end
