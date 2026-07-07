# frozen_string_literal: true

require "revdev"
require "set"

module Fusuma
  module Plugin
    module Remap
      class TwoFingerScrollEmulator
        include Revdev

        SYNTHETIC_TRACKING_ID_BASE = 1_000_000
        QUINTTAP = 0x148

        TOOL_BUTTONS = [
          BTN_TOOL_FINGER,
          BTN_TOOL_DOUBLETAP,
          BTN_TOOL_TRIPLETAP,
          BTN_TOOL_QUADTAP,
          QUINTTAP
        ].freeze

        def initialize(device:)
          @slot_min, @slot_max = axis_range(device, ABS_MT_SLOT, fallback_min: 0, fallback_max: 1)
          @x_min, @x_max = axis_range(device, ABS_MT_POSITION_X, fallback_min: 0, fallback_max: 1000)
          @y_min, @y_max = axis_range(device, ABS_MT_POSITION_Y, fallback_min: 0, fallback_max: 1000)
          @x_offset_size = ((@x_max - @x_min) * 0.15).round

          @slots = Hash.new { |hash, slot| hash[slot] = {tracking_id: nil, x: nil, y: nil, new_touch: false} }
          @current_slot = @slot_min
          @frame_events = []
          @frame_motion_slots = Set.new
          @scroll_mode = false
          @synthetic = nil
          @tracking_sequence = 0
        end

        def set_scroll_mode(enabled)
          enabled = !!enabled
          return [] if @scroll_mode == enabled

          buffered_frame = drain_frame_events
          @scroll_mode = enabled
          return buffered_frame if enabled

          buffered_frame + release_synthetic_frame(real_finger_count)
        end

        def process(input_event)
          parse_event(input_event)

          unless @scroll_mode || synthetic_active?
            return [input_event]
          end

          @frame_events << input_event
          return [] unless syn_report?(input_event)

          flush_frame
        end

        private

        def axis_range(device, axis, fallback_min:, fallback_max:)
          info = device.absinfo_for_axis(axis)
          [info.fetch(:absmin, fallback_min), info.fetch(:absmax, fallback_max)]
        rescue
          [fallback_min, fallback_max]
        end

        def parse_event(input_event)
          case input_event.type
          when EV_ABS
            parse_abs_event(input_event)
          when EV_SYN
            clear_new_touch_flags if syn_report?(input_event)
          end
        end

        def parse_abs_event(input_event)
          case input_event.code
          when ABS_MT_SLOT
            @current_slot = input_event.value
            @slots[@current_slot]
          when ABS_MT_TRACKING_ID
            slot_state = @slots[@current_slot]
            slot_state[:tracking_id] = input_event.value
            slot_state[:new_touch] = input_event.value != -1
          when ABS_MT_POSITION_X
            record_position(:x, input_event.value)
          when ABS_MT_POSITION_Y
            record_position(:y, input_event.value)
          end
        end

        def record_position(axis, value)
          slot_state = @slots[@current_slot]
          if real_slot_active?(@current_slot) && !slot_state[:new_touch] && !slot_state[axis].nil? && slot_state[axis] != value
            @frame_motion_slots.add(@current_slot)
          end
          slot_state[axis] = value
        end

        def clear_new_touch_flags
          @slots.each_value { |slot_state| slot_state[:new_touch] = false }
        end

        def drain_frame_events
          frame = @frame_events
          @frame_events = []
          @frame_motion_slots = Set.new
          frame
        end

        def flush_frame
          frame = @frame_events
          motion_slots = @frame_motion_slots
          @frame_events = []
          @frame_motion_slots = Set.new

          count = real_finger_count
          if synthetic_active? && (count.zero? || count >= 2)
            return frame_with_synthetic_release(frame, count)
          end

          if @scroll_mode
            real_slot = single_real_slot
            if !synthetic_active? && count == 1 && motion_slots.include?(real_slot)
              return frame unless activate_synthetic(real_slot)

              return frame_with_synthetic_touch(frame, real_slot, include_tracking_id: true)
            end

            if synthetic_active? && count == 1
              return frame_with_synthetic_touch(frame, real_slot, include_tracking_id: false)
            end
          end

          frame
        end

        def synthetic_active?
          !@synthetic.nil?
        end

        def real_slot_active?(slot)
          tracking_id = @slots[slot][:tracking_id]
          !tracking_id.nil? && tracking_id != -1
        end

        def real_slots
          (@slot_min..@slot_max).select { |slot| real_slot_active?(slot) }
        end

        def real_finger_count
          real_slots.size
        end

        def single_real_slot
          slots = real_slots
          (slots.size == 1) ? slots.first : nil
        end

        def activate_synthetic(real_slot)
          synthetic_slot = available_synthetic_slot
          return false unless synthetic_slot

          real = @slots[real_slot]
          return false if real[:x].nil? || real[:y].nil?

          @tracking_sequence += 1
          real_x = real[:x]
          offset = (real_x > ((@x_min + @x_max) / 2)) ? -@x_offset_size : @x_offset_size

          @synthetic = {
            slot: synthetic_slot,
            tracking_id: SYNTHETIC_TRACKING_ID_BASE + @tracking_sequence,
            offset: offset
          }
          true
        end

        def available_synthetic_slot
          real = real_slots.to_set
          (@slot_min..@slot_max).to_a.reverse.find { |slot| !real.include?(slot) }
        end

        def frame_with_synthetic_touch(frame, real_slot, include_tracking_id:)
          return frame unless real_slot && @synthetic

          without_syn = frame_without_syn_or_tool_buttons(frame)
          synthetic_x, synthetic_y = synthetic_position_for(real_slot)

          events = without_syn.dup
          events << input_event(EV_ABS, ABS_MT_SLOT, @synthetic[:slot])
          events << input_event(EV_ABS, ABS_MT_TRACKING_ID, @synthetic[:tracking_id]) if include_tracking_id
          events << input_event(EV_ABS, ABS_MT_POSITION_X, synthetic_x)
          events << input_event(EV_ABS, ABS_MT_POSITION_Y, synthetic_y)
          events.concat(tool_events(2))
          events << input_event(EV_KEY, BTN_TOUCH, 1) unless frame_has_btn_touch?(frame)
          events << input_event(EV_ABS, ABS_MT_SLOT, real_slot)
          events << syn_event
          events
        end

        def frame_with_synthetic_release(frame, real_count)
          events = frame_without_syn_or_tool_buttons(frame).dup
          events.concat(release_synthetic_events(real_count, restore_slot: single_real_slot || @current_slot))
          events << syn_event
          events
        end

        def release_synthetic_frame(real_count)
          return [] unless synthetic_active?

          events = release_synthetic_events(real_count, restore_slot: single_real_slot || @current_slot)
          events << syn_event
          events
        end

        def release_synthetic_events(real_count, restore_slot:)
          synthetic_slot = @synthetic[:slot]
          @synthetic = nil

          events = [input_event(EV_ABS, ABS_MT_SLOT, synthetic_slot)]
          events << input_event(EV_ABS, ABS_MT_TRACKING_ID, -1) unless real_slot_active?(synthetic_slot)
          events.concat(tool_events(real_count))
          events << input_event(EV_KEY, BTN_TOUCH, real_count.positive? ? 1 : 0)
          events << input_event(EV_ABS, ABS_MT_SLOT, restore_slot) unless restore_slot.nil?
          events
        end

        def synthetic_position_for(real_slot)
          real = @slots[real_slot]
          x = clamp(real[:x] + @synthetic[:offset], @x_min, @x_max)
          y = clamp(real[:y], @y_min, @y_max)
          [x, y]
        end

        def clamp(value, min, max)
          value.clamp(min, max)
        end

        def tool_events(finger_count)
          [
            input_event(EV_KEY, BTN_TOOL_FINGER, (finger_count == 1) ? 1 : 0),
            input_event(EV_KEY, BTN_TOOL_DOUBLETAP, (finger_count == 2) ? 1 : 0),
            input_event(EV_KEY, BTN_TOOL_TRIPLETAP, (finger_count == 3) ? 1 : 0),
            input_event(EV_KEY, BTN_TOOL_QUADTAP, (finger_count == 4) ? 1 : 0),
            input_event(EV_KEY, QUINTTAP, (finger_count >= 5) ? 1 : 0)
          ]
        end

        def frame_without_syn_or_tool_buttons(frame)
          frame.reject { |input_event| syn_report?(input_event) || tool_button?(input_event) }
        end

        def frame_has_btn_touch?(frame)
          frame.any? { |input_event| input_event.type == EV_KEY && input_event.code == BTN_TOUCH }
        end

        def tool_button?(input_event)
          input_event.type == EV_KEY && TOOL_BUTTONS.include?(input_event.code)
        end

        def syn_report?(input_event)
          input_event.type == EV_SYN && input_event.code == SYN_REPORT
        end

        def syn_event
          input_event(EV_SYN, SYN_REPORT, 0)
        end

        def input_event(type, code, value)
          Revdev::InputEvent.new(nil, type, code, value)
        end
      end
    end
  end
end
