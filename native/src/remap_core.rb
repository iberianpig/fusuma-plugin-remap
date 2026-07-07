# frozen_string_literal: true

require_relative "constants"
require_relative "json_writer"
require_relative "keycodes"
require_relative "map_entry"
require_relative "modifier_state"

class MappingState
  attr_reader :layer_token, :active_simple_entries, :pending_combo_entries

  def initialize
    @layer_token = "null"
    @active_simple_entries = {}
    @pending_simple_entries = {}
    @pending_combo_entries = {}
    @layer_changed = false
  end

  def update(layer_token, entries, keys_released)
    @layer_token = layer_token
    simple, combo = separate_entries(entries)
    @pending_simple_entries = simple
    @pending_combo_entries = combo
    if keys_released
      @active_simple_entries = @pending_simple_entries
      @layer_changed = false
    else
      @layer_changed = true
    end
  end

  def refresh(keys_released)
    return unless @layer_changed
    return unless keys_released

    @active_simple_entries = @pending_simple_entries
    @layer_changed = false
  end

  private

  def separate_entries(entries)
    simple = {"__seed__" => MapEntry.new("simple", [""])}
    combo = {"__seed__" => MapEntry.new("swallow", [])}

    entries.keys.each do |from|
      entry = entries[from]
      if entry.kind == "simple"
        simple[from] = entry
      else
        combo[from] = entry
      end
    end

    [simple, combo]
  end
end

class RemapCore
  def initialize
    @states = {}
    @modifier_state = ModifierState.new
    @pressed_virtual_keys = {"LEFTCTRL" => 1}
    @pressed_virtual_keys.delete("LEFTCTRL")
    @pressed_key_codes = {"0" => 0}
    @pressed_key_codes.delete("0")
    @pressed_key_names = {"0" => ""}
    @pressed_key_names.delete("0")
  end

  def update_mapping(device_name, layer_token, entries)
    state = state_for(device_name)
    state.update(layer_token, entries, virtual_keyboard_all_key_released?)
  end

  def process(device_name, event_type, event_code, event_value)
    events = [""]
    lines = [""]
    lines.pop

    if event_type != Const::EV_KEY
      emit_event(events, event_type, event_code, event_value)
      return RemapResult.new(events, lines)
    end

    state = state_for(device_name)
    state.refresh(virtual_keyboard_all_key_released?)

    input_key = code_to_key(event_code)
    if input_key.nil?
      emit_event(events, event_type, event_code, event_value)
      return RemapResult.new(events, lines)
    end

    effective_key = apply_simple_remap(state.active_simple_entries, input_key)

    @modifier_state.update(effective_key, event_value)
    if event_value != 2
      lines.push(key_event_line(input_key, event_value, state.layer_token))
    end

    remapped, modifier_remap = find_remapping(state.pending_combo_entries, effective_key)
    if remapped.nil?
      handle_unmapped(events, event_type, event_code, event_value, input_key, effective_key)
      return RemapResult.new(events, lines)
    end

    if remapped.kind == "swallow"
      return RemapResult.new(events, lines)
    end

    if remapped.kind == "seq"
      execute_modifier_remap(events, remapped.to, event_type) if event_value == 1
      return RemapResult.new(events, lines)
    end

    target = first_target(remapped)
    return RemapResult.new(events, lines) if target.empty?

    if modifier_remap && event_value == 1
      execute_modifier_remap(events, remapped.to, event_type)
      return RemapResult.new(events, lines)
    end

    if target.include?("+")
      send_key_sequence(events, remapped.to, event_type) if event_value == 1
      return RemapResult.new(events, lines)
    end

    remapped_code = key_to_code(target)
    if remapped_code.nil?
      emit_event(events, event_type, event_code, event_value)
      return RemapResult.new(events, lines)
    end

    output_code = get_or_record_key_code(event_code, remapped_code, event_value)
    virtual_key = get_or_record_key_name(event_code, target, event_value)
    update_virtual_key_state(virtual_key, event_value)
    emit_event(events, event_type, output_code, event_value)
    RemapResult.new(events, lines)
  end

  def code_to_key(code)
    Keycodes::KEYMAP[code]
  end

  def key_to_code(key)
    return nil if key.nil?

    normalized = key.to_s.upcase
    return Keycodes::CODEMAP[normalized] if normalized.start_with?("BTN_")

    Keycodes::CODEMAP[normalized]
  end

  private

  def state_for(device_name)
    @states[device_name] ||= MappingState.new
  end

  def apply_simple_remap(mapping, key)
    entry = mapping[key]
    return key if entry.nil?
    return key unless entry.kind == "simple"

    target = first_target(entry)
    target.empty? ? key : target
  end

  def find_remapping(mapping, input_key)
    if @modifier_state.pressed_modifiers.any?
      combined_key = @modifier_state.current_combination(input_key)
      remapped = mapping[combined_key]
      unless remapped.nil?
        modifier_remap = !@modifier_state.modifier?(input_key)
        return [remapped, modifier_remap]
      end
    end

    remapped = mapping[input_key]
    [remapped, false]
  end

  def handle_unmapped(events, event_type, event_code, event_value, input_key, effective_key)
    if effective_key != input_key
      remapped_code = key_to_code(effective_key)
      if remapped_code.nil?
        emit_event(events, event_type, event_code, event_value)
        return
      end

      output_code = get_or_record_key_code(event_code, remapped_code, event_value)
      virtual_key = get_or_record_key_name(event_code, effective_key, event_value)
      update_virtual_key_state(virtual_key, event_value)
      emit_event(events, event_type, output_code, event_value)
    else
      output_code = get_or_record_key_code(event_code, event_code, event_value)
      virtual_key = get_or_record_key_name(event_code, input_key, event_value)
      update_virtual_key_state(virtual_key, event_value)
      emit_event(events, event_type, output_code, event_value)
    end
  end

  def emit_event(events, type, code, value)
    events.push(type.to_s + "," + code.to_s + "," + value.to_s)
  end

  def first_target(entry)
    return "" if entry.to.empty?

    entry.to[0]
  end

  def get_or_record_key_code(physical_code, output_code, event_value)
    key = physical_code.to_s
    if event_value == 1
      @pressed_key_codes[key] = output_code
      output_code
    elsif event_value == 0
      recorded_code = @pressed_key_codes[key]
      @pressed_key_codes.delete(key)
      recorded_code || output_code
    else
      output_code
    end
  end

  def get_or_record_key_name(physical_code, key_name, event_value)
    key = physical_code.to_s
    if event_value == 1
      @pressed_key_names[key] = key_name
      key_name
    elsif event_value == 0
      recorded_name = @pressed_key_names[key]
      @pressed_key_names.delete(key)
      recorded_name || key_name
    else
      key_name
    end
  end

  def update_virtual_key_state(key_name, event_value)
    if event_value == 1
      @pressed_virtual_keys[key_name] = 1
    elsif event_value == 0
      @pressed_virtual_keys.delete(key_name)
    end
  end

  def virtual_keyboard_all_key_released?
    @pressed_virtual_keys.empty?
  end

  def release_current_modifiers(events, event_type)
    @modifier_state.pressed_modifiers.each do |modifier_key|
      code = key_to_code(modifier_key)
      emit_event(events, event_type, code, 0) unless code.nil?
    end
  end

  def restore_current_modifiers(events, event_type)
    @modifier_state.pressed_modifiers.each do |modifier_key|
      code = key_to_code(modifier_key)
      emit_event(events, event_type, code, 1) unless code.nil?
    end
  end

  def execute_modifier_remap(events, key_inputs, event_type)
    release_current_modifiers(events, event_type)
    send_key_sequence(events, key_inputs, event_type)
    restore_current_modifiers(events, event_type)
  end

  def send_key_sequence(events, key_inputs, event_type)
    key_inputs.each do |key_input|
      send_key_combination(events, key_input, event_type)
    end
  end

  def send_key_combination(events, key_input, event_type)
    keys = key_input.split("+")

    keys.each do |key|
      code = key_to_code(key)
      emit_event(events, event_type, code, 1) unless code.nil?
    end

    i = keys.length - 1
    while i >= 0
      code = key_to_code(keys[i])
      emit_event(events, event_type, code, 0) unless code.nil?
      i -= 1
    end
  end

  def key_event_line(key, value, layer_token)
    "{\"t\":\"key\",\"key\":" + JsonWriter.quote(key) +
      ",\"status\":" + value.to_s +
      ",\"layer\":" + (layer_token.empty? ? "null" : layer_token) + "}"
  end
end
