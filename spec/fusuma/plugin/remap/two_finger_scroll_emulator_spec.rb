# frozen_string_literal: true

require "spec_helper"
require "fusuma/plugin/remap/two_finger_scroll_emulator"

RSpec.describe Fusuma::Plugin::Remap::TwoFingerScrollEmulator do
  let(:device) { double("Revdev::EventDevice") }
  let(:emulator) { described_class.new(device: device) }
  let(:synthetic_slot) { 4 }

  before do
    allow(device).to receive(:absinfo_for_axis).with(Revdev::ABS_MT_SLOT).and_return(absmin: 0, absmax: 4)
    allow(device).to receive(:absinfo_for_axis).with(Revdev::ABS_MT_POSITION_X).and_return(absmin: 0, absmax: 1000)
    allow(device).to receive(:absinfo_for_axis).with(Revdev::ABS_MT_POSITION_Y).and_return(absmin: 0, absmax: 1000)
  end

  def event(type, code, value)
    Revdev::InputEvent.new(nil, type, code, value)
  end

  def abs(code, value)
    event(Revdev::EV_ABS, code, value)
  end

  def key(code, value)
    event(Revdev::EV_KEY, code, value)
  end

  def syn
    event(Revdev::EV_SYN, Revdev::SYN_REPORT, 0)
  end

  def process_frame(*events)
    events.flat_map { |input_event| emulator.process(input_event) }
  end

  def tuples(events)
    events.map { |input_event| [input_event.type, input_event.code, input_event.value] }
  end

  def tracking_ids_by_slot(events)
    current_slot = 0
    events.each_with_object(Hash.new { |hash, slot| hash[slot] = [] }) do |input_event, tracking_ids|
      if input_event.type == Revdev::EV_ABS && input_event.code == Revdev::ABS_MT_SLOT
        current_slot = input_event.value
      elsif input_event.type == Revdev::EV_ABS && input_event.code == Revdev::ABS_MT_TRACKING_ID
        tracking_ids[current_slot] << input_event.value
      end
    end
  end

  def touch_begin(x: 400, y: 500, tracking_id: 10, slot: 0)
    process_frame(
      abs(Revdev::ABS_MT_SLOT, slot),
      abs(Revdev::ABS_MT_TRACKING_ID, tracking_id),
      abs(Revdev::ABS_MT_POSITION_X, x),
      abs(Revdev::ABS_MT_POSITION_Y, y),
      key(Revdev::BTN_TOUCH, 1),
      key(Revdev::BTN_TOOL_FINGER, 1),
      syn
    )
  end

  def touch_end(slot: 0)
    process_frame(
      abs(Revdev::ABS_MT_SLOT, slot),
      abs(Revdev::ABS_MT_TRACKING_ID, -1),
      key(Revdev::BTN_TOUCH, 0),
      key(Revdev::BTN_TOOL_FINGER, 0),
      syn
    )
  end

  def first_scroll_motion(x: 450, y: 520)
    process_frame(
      abs(Revdev::ABS_MT_POSITION_X, x),
      abs(Revdev::ABS_MT_POSITION_Y, y),
      syn
    )
  end

  describe "#process" do
    it "passes events through immediately when scroll mode is off" do
      input_event = abs(Revdev::ABS_MT_POSITION_X, 100)

      expect(emulator.process(input_event)).to eq([input_event])
    end

    it "does not inject a synthetic finger until the real finger moves" do
      emulator.set_scroll_mode(true)

      output = touch_begin

      expect(tuples(output)).not_to include([Revdev::EV_ABS, Revdev::ABS_MT_SLOT, synthetic_slot])
      expect(tuples(output)).not_to include([Revdev::EV_KEY, Revdev::BTN_TOOL_DOUBLETAP, 1])
    end

    it "injects the synthetic finger in the first motion frame and restores the real slot" do
      emulator.set_scroll_mode(true)
      touch_begin

      output = first_scroll_motion

      expect(tuples(output)).to include([Revdev::EV_ABS, Revdev::ABS_MT_SLOT, synthetic_slot])
      expect(tuples(output)).to include([Revdev::EV_ABS, Revdev::ABS_MT_POSITION_X, 600])
      expect(tuples(output)).to include([Revdev::EV_ABS, Revdev::ABS_MT_POSITION_Y, 520])
      expect(tuples(output)).to include([Revdev::EV_KEY, Revdev::BTN_TOOL_FINGER, 0])
      expect(tuples(output)).to include([Revdev::EV_KEY, Revdev::BTN_TOOL_DOUBLETAP, 1])
      expect(tuples(output)[-2]).to eq([Revdev::EV_ABS, Revdev::ABS_MT_SLOT, 0])
      expect(tuples(output).last).to eq([Revdev::EV_SYN, Revdev::SYN_REPORT, 0])
    end

    it "keeps slot coordinates across touch restarts and ignores begin-frame motion" do
      emulator.set_scroll_mode(true)
      touch_begin(x: 450, y: 500)
      first_scroll_motion(x: 450, y: 520)
      touch_end

      begin_output = process_frame(
        abs(Revdev::ABS_MT_SLOT, 0),
        abs(Revdev::ABS_MT_TRACKING_ID, 20),
        abs(Revdev::ABS_MT_POSITION_Y, 700),
        key(Revdev::BTN_TOUCH, 1),
        key(Revdev::BTN_TOOL_FINGER, 1),
        syn
      )

      expect(tuples(begin_output)).not_to include([Revdev::EV_ABS, Revdev::ABS_MT_SLOT, synthetic_slot])
      expect(tuples(begin_output)).not_to include([Revdev::EV_KEY, Revdev::BTN_TOOL_DOUBLETAP, 1])

      motion_output = process_frame(
        abs(Revdev::ABS_MT_POSITION_Y, 720),
        syn
      )

      expect(tuples(motion_output)).to include([Revdev::EV_ABS, Revdev::ABS_MT_SLOT, synthetic_slot])
      expect(tuples(motion_output)).to include([Revdev::EV_ABS, Revdev::ABS_MT_POSITION_X, 600])
      expect(tuples(motion_output)).to include([Revdev::EV_ABS, Revdev::ABS_MT_POSITION_Y, 720])
      expect(tuples(motion_output)).to include([Revdev::EV_KEY, Revdev::BTN_TOOL_DOUBLETAP, 1])
    end

    context "when the device has no free multitouch slot" do
      before do
        allow(device).to receive(:absinfo_for_axis).with(Revdev::ABS_MT_SLOT).and_return(absmin: 0, absmax: 0)
      end

      it "passes motion through without injecting nil-valued synthetic events" do
        emulator.set_scroll_mode(true)
        touch_begin

        output = first_scroll_motion

        expect(tuples(output)).to eq([
          [Revdev::EV_ABS, Revdev::ABS_MT_POSITION_X, 450],
          [Revdev::EV_ABS, Revdev::ABS_MT_POSITION_Y, 520],
          [Revdev::EV_SYN, Revdev::SYN_REPORT, 0]
        ])
        expect(tuples(output)).not_to include([Revdev::EV_KEY, Revdev::BTN_TOOL_DOUBLETAP, 1])
        expect(output.map(&:value)).not_to include(nil)
      end
    end

    it "passes motion through when the real slot has incomplete coordinates" do
      emulator.set_scroll_mode(true)
      process_frame(
        abs(Revdev::ABS_MT_SLOT, 0),
        abs(Revdev::ABS_MT_TRACKING_ID, 10),
        abs(Revdev::ABS_MT_POSITION_X, 450),
        syn
      )

      output = process_frame(
        abs(Revdev::ABS_MT_POSITION_X, 460),
        syn
      )

      expect(tuples(output)).to eq([
        [Revdev::EV_ABS, Revdev::ABS_MT_POSITION_X, 460],
        [Revdev::EV_SYN, Revdev::SYN_REPORT, 0]
      ])
      expect(tuples(output)).not_to include([Revdev::EV_KEY, Revdev::BTN_TOOL_DOUBLETAP, 1])
    end

    it "mirrors subsequent real finger movement to the synthetic slot" do
      emulator.set_scroll_mode(true)
      touch_begin
      first_scroll_motion

      output = process_frame(
        abs(Revdev::ABS_MT_POSITION_X, 500),
        abs(Revdev::ABS_MT_POSITION_Y, 530),
        syn
      )

      expect(tuples(output)).to include([Revdev::EV_ABS, Revdev::ABS_MT_SLOT, synthetic_slot])
      expect(tuples(output)).to include([Revdev::EV_ABS, Revdev::ABS_MT_POSITION_X, 650])
      expect(tuples(output)).to include([Revdev::EV_ABS, Revdev::ABS_MT_POSITION_Y, 530])
      synthetic_tracking_ids = output.select { |input_event|
        input_event.type == Revdev::EV_ABS &&
          input_event.code == Revdev::ABS_MT_TRACKING_ID &&
          input_event.value != -1
      }
      expect(synthetic_tracking_ids).to be_empty
    end

    it "releases the synthetic finger when a second real finger appears" do
      emulator.set_scroll_mode(true)
      touch_begin
      first_scroll_motion

      output = process_frame(
        abs(Revdev::ABS_MT_SLOT, 1),
        abs(Revdev::ABS_MT_TRACKING_ID, 11),
        abs(Revdev::ABS_MT_POSITION_X, 200),
        abs(Revdev::ABS_MT_POSITION_Y, 300),
        key(Revdev::BTN_TOOL_FINGER, 0),
        key(Revdev::BTN_TOOL_DOUBLETAP, 1),
        syn
      )

      expect(tuples(output)).to include([Revdev::EV_ABS, Revdev::ABS_MT_SLOT, synthetic_slot])
      expect(tuples(output)).to include([Revdev::EV_ABS, Revdev::ABS_MT_TRACKING_ID, -1])
      expect(tuples(output)).to include([Revdev::EV_KEY, Revdev::BTN_TOOL_DOUBLETAP, 1])
    end

    it "releases the synthetic finger when a later real finger uses the synthetic slot" do
      emulator.set_scroll_mode(true)
      touch_begin
      first_scroll_motion

      output = process_frame(
        abs(Revdev::ABS_MT_SLOT, synthetic_slot),
        abs(Revdev::ABS_MT_TRACKING_ID, 11),
        abs(Revdev::ABS_MT_POSITION_X, 200),
        abs(Revdev::ABS_MT_POSITION_Y, 300),
        key(Revdev::BTN_TOOL_FINGER, 0),
        key(Revdev::BTN_TOOL_DOUBLETAP, 1),
        syn
      )

      expect(tuples(output)).to include([Revdev::EV_ABS, Revdev::ABS_MT_SLOT, synthetic_slot])
      expect(tracking_ids_by_slot(output)[synthetic_slot]).to include(11)
      expect(tracking_ids_by_slot(output)[synthetic_slot]).not_to include(-1)
      expect(tuples(output)).to include([Revdev::EV_KEY, Revdev::BTN_TOOL_DOUBLETAP, 1])
    end

    it "keeps scroll mode across touch restarts while the key remains pressed" do
      emulator.set_scroll_mode(true)
      touch_begin
      first_scroll_motion

      touch_end

      begin_output = touch_begin(x: 100, y: 200, tracking_id: 20)

      expect(tuples(begin_output)).not_to include([Revdev::EV_ABS, Revdev::ABS_MT_SLOT, synthetic_slot])
      expect(tuples(begin_output)).not_to include([Revdev::EV_KEY, Revdev::BTN_TOOL_DOUBLETAP, 1])

      motion_output = first_scroll_motion(x: 130, y: 220)

      expect(tuples(motion_output)).to include([Revdev::EV_ABS, Revdev::ABS_MT_SLOT, synthetic_slot])
      expect(tuples(motion_output)).to include([Revdev::EV_KEY, Revdev::BTN_TOOL_DOUBLETAP, 1])
    end

    it "does not restart scrolling after scroll mode is disabled" do
      emulator.set_scroll_mode(true)
      touch_begin
      first_scroll_motion
      touch_end

      emulator.set_scroll_mode(false)
      touch_begin(x: 100, y: 200, tracking_id: 20)
      output = first_scroll_motion

      expect(tuples(output)).not_to include([Revdev::EV_KEY, Revdev::BTN_TOOL_DOUBLETAP, 1])
    end
  end

  describe "#set_scroll_mode" do
    it "does nothing for a key press and release with no touch motion" do
      expect(emulator.set_scroll_mode(true)).to eq([])
      expect(emulator.set_scroll_mode(false)).to eq([])
    end

    it "returns a release frame when scroll mode is disabled during an active synthetic touch" do
      emulator.set_scroll_mode(true)
      touch_begin
      first_scroll_motion

      output = emulator.set_scroll_mode(false)

      expect(tuples(output)).to include([Revdev::EV_ABS, Revdev::ABS_MT_SLOT, synthetic_slot])
      expect(tuples(output)).to include([Revdev::EV_ABS, Revdev::ABS_MT_TRACKING_ID, -1])
      expect(tuples(output)).to include([Revdev::EV_KEY, Revdev::BTN_TOOL_DOUBLETAP, 0])
      expect(tuples(output)).to include([Revdev::EV_KEY, Revdev::BTN_TOOL_FINGER, 1])
      expect(tuples(output)).to include([Revdev::EV_KEY, Revdev::BTN_TOUCH, 1])
      expect(tuples(output).last).to eq([Revdev::EV_SYN, Revdev::SYN_REPORT, 0])
    end

    it "flushes a buffered partial frame before disabling scroll mode" do
      emulator.set_scroll_mode(true)
      touch_begin
      first_scroll_motion

      buffered_events = [
        abs(Revdev::ABS_MT_SLOT, 0),
        abs(Revdev::ABS_MT_TRACKING_ID, -1)
      ]
      buffered_events.each { |input_event| expect(emulator.process(input_event)).to eq([]) }

      output = emulator.set_scroll_mode(false)

      expect(tuples(output).first(2)).to eq(tuples(buffered_events))
      expect(tuples(output)).to include([Revdev::EV_ABS, Revdev::ABS_MT_SLOT, synthetic_slot])
      expect(tuples(output)).to include([Revdev::EV_ABS, Revdev::ABS_MT_TRACKING_ID, -1])

      remaining_output = process_frame(
        key(Revdev::BTN_TOUCH, 0),
        key(Revdev::BTN_TOOL_FINGER, 0),
        syn
      )

      expect(tuples(remaining_output)).to eq([
        [Revdev::EV_KEY, Revdev::BTN_TOUCH, 0],
        [Revdev::EV_KEY, Revdev::BTN_TOOL_FINGER, 0],
        [Revdev::EV_SYN, Revdev::SYN_REPORT, 0]
      ])
    end
  end
end
