# frozen_string_literal: true

require "revdev"
require "set"
require "fusuma/multi_logger"

module Fusuma
  module Plugin
    module Remap
      class TwoFingerScrollEmulator
        include Revdev

        SYNTHETIC_TRACKING_ID_BASE = 1_000_000
        QUINTTAP = 0x148
        # Revdev ships MT_TOOL_FINGER and MT_TOOL_PEN but not MT_TOOL_PALM
        MT_TOOL_PALM = 2

        TOOL_BUTTONS = [
          BTN_TOOL_FINGER,
          BTN_TOOL_DOUBLETAP,
          BTN_TOOL_TRIPLETAP,
          BTN_TOOL_QUADTAP,
          QUINTTAP
        ].freeze

        def initialize(device:)
          @slot_min, @slot_max = axis_range(device, ABS_MT_SLOT, fallback_min: 0, fallback_max: 1)
          # The virtual touchpad is created with one slot more than the
          # physical device (see UinputTouchpad#create_from_device), and that
          # extra slot belongs to the synthetic finger alone. A real touch can
          # never land on it, so the synthetic finger inherits no stale palm
          # attribute and never overwrites a live tracking id.
          @synthetic_slot = @slot_max + 1
          @x_min, @x_max = axis_range(device, ABS_MT_POSITION_X, fallback_min: 0, fallback_max: 1000)
          @y_min, @y_max = axis_range(device, ABS_MT_POSITION_Y, fallback_min: 0, fallback_max: 1000)
          @x_offset_size = ((@x_max - @x_min) * 0.15).round

          @slots = Hash.new { |hash, slot| hash[slot] = {tracking_id: nil, x: nil, y: nil, new_touch: false, tool_type: nil} }
          @current_slot = @slot_min
          @frame_events = []
          @frame_motion_slots = Set.new
          @scroll_mode = false
          @synthetic = nil
          @tracking_sequence = 0
          @in_frame = false
          @pending_scroll_mode = nil
          @emitted_tool_count = nil
        end

        def set_scroll_mode(enabled)
          enabled = !!enabled
          target = @pending_scroll_mode.nil? ? @scroll_mode : @pending_scroll_mode
          return [] if target == enabled

          # Switching mid-frame would strand buffered events and split the
          # frame at the injected SYN, so defer until the frame completes
          if @in_frame
            MultiLogger.debug("TwoFingerScrollEmulator: defer scroll_mode=#{enabled} until frame end")
            @pending_scroll_mode = enabled
            return []
          end

          apply_scroll_mode(enabled)
        end

        def process(input_event)
          parse_event(input_event)

          unless @scroll_mode || synthetic_active?
            result = [input_event]
            result.concat(apply_pending_scroll_mode) if syn_report?(input_event)
            return result
          end

          @frame_events << input_event
          return [] unless syn_report?(input_event)

          flush_frame.concat(apply_pending_scroll_mode)
        end

        private

        def axis_range(device, axis, fallback_min:, fallback_max:)
          info = device.absinfo_for_axis(axis)
          [info.fetch(:absmin, fallback_min), info.fetch(:absmax, fallback_max)]
        rescue
          [fallback_min, fallback_max]
        end

        def apply_pending_scroll_mode
          return [] if @pending_scroll_mode.nil?

          enabled = @pending_scroll_mode
          @pending_scroll_mode = nil
          return [] if @scroll_mode == enabled

          apply_scroll_mode(enabled)
        end

        def apply_scroll_mode(enabled)
          MultiLogger.debug("TwoFingerScrollEmulator: scroll_mode=#{enabled}")
          @scroll_mode = enabled
          return [] if enabled

          release_synthetic_frame(contact_count)
        end

        def parse_event(input_event)
          @in_frame = !syn_report?(input_event)

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
          when ABS_MT_TRACKING_ID
            slot_state = @slots[@current_slot]
            # x/y are kept across tracking resets: evdev suppresses ABS events
            # with unchanged values, so a new touch landing on the previous
            # coordinates never resends X/Y
            slot_state[:tracking_id] = input_event.value
            slot_state[:new_touch] = input_event.value != -1
          when ABS_MT_TOOL_TYPE
            # Mirror libinput: is_tool_palm is set from this event and is never
            # cleared by a tracking id reset, so the value sticks to the slot
            @slots[@current_slot][:tool_type] = input_event.value
          when ABS_MT_POSITION_X
            record_position(:x, input_event.value)
          when ABS_MT_POSITION_Y
            record_position(:y, input_event.value)
          end
        end

        def record_position(axis, value)
          slot_state = @slots[@current_slot]
          # :new_touch excludes the touch-down frame: a re-touch away from the
          # carried-over position is a new touch, not finger motion
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
          motion_slots = @frame_motion_slots
          @frame_events = []
          @frame_motion_slots = Set.new
          [frame, motion_slots]
        end

        def flush_frame
          frame, motion_slots = drain_frame_events

          active_slots = real_slots
          count = active_slots.size
          if synthetic_active? && (count.zero? || count >= 2)
            # The palm stays on the touchpad after the synthetic finger goes, so the
            # count handed to the release frame counts contacts, not fingers
            return frame_with_synthetic_release(frame, contact_count)
          end

          if @scroll_mode
            real_slot = (count == 1) ? active_slots.first : nil
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
          (@slot_min..@slot_max).select { |slot| real_slot_active?(slot) && !palm_slot?(slot) }
        end

        # libinput excludes palms from the gesture finger count, so counting one
        # here would leave the user with a single effective finger and no scroll
        def palm_slot?(slot)
          @slots[slot][:tool_type] == MT_TOOL_PALM
        end

        # Every live contact, palms included. libinput matches BTN_TOOL_* against
        # the number of slots it sees, not against the fingers it counts
        def contact_count
          (@slot_min..@slot_max).count { |slot| real_slot_active?(slot) }
        end

        def activate_synthetic(real_slot)
          real = @slots[real_slot]
          # Position can still be unknown right after startup (before the first
          # X/Y events ever arrive); wait instead of guessing
          return false if real[:x].nil? || real[:y].nil?

          @tracking_sequence += 1
          real_x = real[:x]
          real_y = real[:y]
          offset = (real_x > ((@x_min + @x_max) / 2)) ? -@x_offset_size : @x_offset_size

          @synthetic = {
            slot: @synthetic_slot,
            tracking_id: SYNTHETIC_TRACKING_ID_BASE + @tracking_sequence,
            offset: offset,
            last_x: (real_x + offset).clamp(@x_min, @x_max),
            last_y: real_y.clamp(@y_min, @y_max)
          }
          true
        end

        def frame_with_synthetic_touch(frame, real_slot, include_tracking_id:)
          return frame unless real_slot && @synthetic

          synthetic_x, synthetic_y = synthetic_position_for(real_slot)

          events = frame_without_syn_or_tool_buttons(frame)
          events << input_event(EV_ABS, ABS_MT_SLOT, @synthetic[:slot])
          if include_tracking_id
            events << input_event(EV_ABS, ABS_MT_TRACKING_ID, @synthetic[:tracking_id])
            # The kernel keeps ABS_MT_TOOL_TYPE per slot and libinput never
            # clears is_tool_palm on a new tracking id, so a slot that once
            # held a palm would make the synthetic finger a palm too and drop
            # it from the gesture finger count
            events << input_event(EV_ABS, ABS_MT_TOOL_TYPE, MT_TOOL_FINGER)
          end
          events << input_event(EV_ABS, ABS_MT_POSITION_X, synthetic_x)
          events << input_event(EV_ABS, ABS_MT_POSITION_Y, synthetic_y)
          # The emulator strips every BTN_TOOL_* the physical stream sends, so it
          # owns the count. It changes whenever a contact lands or leaves, not just
          # when the synthetic finger appears, and libinput ends touches in reverse
          # slot order once the count falls behind the number of slots it sees.
          tool_count = contact_count + 1
          if include_tracking_id || tool_count != @emitted_tool_count
            events.concat(tool_events(tool_count))
            @emitted_tool_count = tool_count
          end
          events << input_event(EV_KEY, BTN_TOUCH, 1) if include_tracking_id && !frame_has_btn_touch?(frame)
          events << input_event(EV_ABS, ABS_MT_SLOT, @current_slot)
          events << syn_event
          events
        end

        def frame_with_synthetic_release(frame, remaining_contacts)
          events = frame_without_syn_or_tool_buttons(frame)
          events.concat(release_synthetic_events(remaining_contacts, restore_slot: @current_slot))
          events << syn_event
          events
        end

        def release_synthetic_frame(remaining_contacts)
          return [] unless synthetic_active?

          events = release_synthetic_events(remaining_contacts, restore_slot: @current_slot)
          events << syn_event
          events
        end

        def release_synthetic_events(remaining_contacts, restore_slot:)
          synthetic_slot = @synthetic[:slot]
          @synthetic = nil

          events = [input_event(EV_ABS, ABS_MT_SLOT, synthetic_slot)]
          events << input_event(EV_ABS, ABS_MT_TRACKING_ID, -1) unless real_slot_active?(synthetic_slot)
          events.concat(tool_events(remaining_contacts))
          @emitted_tool_count = remaining_contacts
          events << input_event(EV_KEY, BTN_TOUCH, remaining_contacts.positive? ? 1 : 0)
          events << input_event(EV_ABS, ABS_MT_SLOT, restore_slot) unless restore_slot.nil?
          events
        end

        def synthetic_position_for(real_slot)
          real = @slots[real_slot]
          # Fall back to the last emitted position if an axis is unknown
          @synthetic[:last_x] = (real[:x] + @synthetic[:offset]).clamp(@x_min, @x_max) if real[:x]
          @synthetic[:last_y] = real[:y].clamp(@y_min, @y_max) if real[:y]
          [@synthetic[:last_x], @synthetic[:last_y]]
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
