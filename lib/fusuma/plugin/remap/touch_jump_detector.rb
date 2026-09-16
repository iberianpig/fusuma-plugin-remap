# frozen_string_literal: true

require "revdev"
require "fusuma/multi_logger"

module Fusuma
  module Plugin
    module Remap
      # Observes events written to the virtual touchpad and warns when a
      # continuing touch moves further than the jump threshold within one
      # frame. Xorg's libinput logs the same condition as "Touch jump
      # detected" but rate-limits it to 5 messages per 24h, which makes
      # incidents invisible; this detector has no rate limit and records
      # the offending frame contents.
      class TouchJumpDetector
        include Revdev

        # Fraction of the axis range a touch may travel between two
        # consecutive frames before it is reported as a jump
        JUMP_RATIO = 0.1

        # A gap this long between two forwarded events means the remapper
        # stalled. The kernel timestamps uinput writes at flush time, so a
        # stalled burst collapses many frames onto one instant and libinput
        # reads it as a coordinate jump ("Touch jump detected"). This
        # detector shares the remapper's process, so its own observe gaps
        # measure the stall directly.
        STALL_THRESHOLD_SEC = 0.2

        def initialize(device:, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
          @x_threshold = axis_threshold(device, ABS_MT_POSITION_X)
          @y_threshold = axis_threshold(device, ABS_MT_POSITION_Y)
          @clock = clock
          @last_observed_at = nil
          @touch_active = false
          @slots = Hash.new { |hash, slot| hash[slot] = {} }
          @current_slot = 0
          @frame = Hash.new { |hash, slot| hash[slot] = {} }
          @frame_events = []
        end

        def observe(input_event)
          check_stall
          @frame_events << [input_event.type, input_event.code, input_event.value] unless syn_report?(input_event)

          case input_event.type
          when EV_ABS
            case input_event.code
            when ABS_MT_SLOT
              @current_slot = input_event.value
            when ABS_MT_POSITION_X
              @frame[@current_slot][:x] = input_event.value
            when ABS_MT_POSITION_Y
              @frame[@current_slot][:y] = input_event.value
            when ABS_MT_TRACKING_ID
              @frame[@current_slot][:tracking_id] = input_event.value
            end
          when EV_SYN
            evaluate_frame if syn_report?(input_event)
          end
        end

        private

        def check_stall
          now = @clock.call
          # Only meaningful during an active touch: an idle gap between two
          # gestures is not a stall, and a still finger emits no events at all
          if @touch_active && @last_observed_at
            gap = now - @last_observed_at
            if gap > STALL_THRESHOLD_SEC
              MultiLogger.warn(
                "TouchJumpDetector: stall detected gap=#{(gap * 1000).round}ms " \
                "(forwarding paused; the flushed burst reads as a touch jump)"
              )
            end
          end
          @last_observed_at = now
        end

        def axis_threshold(device, axis)
          info = device.absinfo_for_axis(axis)
          range = info.fetch(:absmax, 1000) - info.fetch(:absmin, 0)
          (range * JUMP_RATIO).round
        rescue
          100
        end

        def evaluate_frame
          @frame.each do |slot, updates|
            state = @slots[slot]
            check_jump(slot, state, updates)
            state.merge!(updates)
          end
          @touch_active = @slots.any? { |_slot, state| !state[:tracking_id].nil? && state[:tracking_id] != -1 }
          @frame = Hash.new { |hash, slot| hash[slot] = {} }
          @frame_events = []
        end

        def syn_report?(input_event)
          input_event.type == EV_SYN && input_event.code == SYN_REPORT
        end

        def check_jump(slot, state, updates)
          # A frame carrying a tracking id starts or ends a touch; distance
          # from the previous touch is not motion
          return if updates.key?(:tracking_id)
          return if state[:x].nil? && state[:y].nil?

          thresholds = {x: @x_threshold, y: @y_threshold}
          jumped = %i[x y].select do |axis|
            !updates[axis].nil? && !state[axis].nil? && (updates[axis] - state[axis]).abs > thresholds[axis]
          end
          return if jumped.empty?

          MultiLogger.warn(
            "TouchJumpDetector: jump detected slot=#{slot} tracking_id=#{state[:tracking_id]} " \
            "x:#{state[:x]}->#{updates.fetch(:x, state[:x])} y:#{state[:y]}->#{updates.fetch(:y, state[:y])} " \
            "frame=#{@frame_events.inspect}"
          )
        end
      end
    end
  end
end
