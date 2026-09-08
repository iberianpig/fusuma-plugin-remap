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
      expect(tuples(output)).to include([Revdev::EV_ABS, Revdev::ABS_MT_TRACKING_ID, -1])
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

    it "carries over the last position when a re-touch omits X/Y (evdev same-value suppression)" do
      emulator.set_scroll_mode(true)
      touch_begin
      first_scroll_motion
      touch_end

      # Re-touch on the same coordinates: evdev suppresses unchanged ABS values,
      # so neither X nor Y arrives with the new tracking ID
      process_frame(
        abs(Revdev::ABS_MT_TRACKING_ID, 20),
        key(Revdev::BTN_TOUCH, 1),
        key(Revdev::BTN_TOOL_FINGER, 1),
        syn
      )

      output = nil
      expect {
        output = process_frame(abs(Revdev::ABS_MT_POSITION_Y, 560), syn)
      }.not_to raise_error

      expect(tuples(output)).to include([Revdev::EV_ABS, Revdev::ABS_MT_SLOT, synthetic_slot])
      # X carried over from the previous touch (450) + offset (150 = 15% of width)
      expect(tuples(output)).to include([Revdev::EV_ABS, Revdev::ABS_MT_POSITION_X, 600])
    end

    it "skips synthetic activation when the position is still unknown" do
      emulator.set_scroll_mode(true)

      # Very first touch never reports X (suppressed), only Y motion follows
      process_frame(
        abs(Revdev::ABS_MT_TRACKING_ID, 10),
        key(Revdev::BTN_TOUCH, 1),
        key(Revdev::BTN_TOOL_FINGER, 1),
        syn
      )
      process_frame(abs(Revdev::ABS_MT_POSITION_Y, 520), syn)

      output = nil
      expect {
        output = process_frame(abs(Revdev::ABS_MT_POSITION_Y, 530), syn)
      }.not_to raise_error

      expect(tuples(output)).not_to include([Revdev::EV_ABS, Revdev::ABS_MT_SLOT, synthetic_slot])
      expect(tuples(output).last).to eq([Revdev::EV_SYN, Revdev::SYN_REPORT, 0])
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

    it "defers disabling until the frame boundary when called mid-frame" do
      emulator.set_scroll_mode(true)
      touch_begin
      first_scroll_motion

      # A frame is in flight (buffered, no SYN yet) when the scroll key is released
      expect(emulator.process(abs(Revdev::ABS_MT_POSITION_X, 470))).to eq([])
      expect(emulator.set_scroll_mode(false)).to eq([])

      output = process_frame(abs(Revdev::ABS_MT_POSITION_Y, 540), syn)

      # The buffered first half of the frame is not lost
      expect(tuples(output)).to include([Revdev::EV_ABS, Revdev::ABS_MT_POSITION_X, 470])
      # The synthetic finger is released after the frame completes
      expect(tuples(output)).to include([Revdev::EV_ABS, Revdev::ABS_MT_TRACKING_ID, -1])
      expect(tuples(output).last).to eq([Revdev::EV_SYN, Revdev::SYN_REPORT, 0])

      # No orphaned events remain: the next event passes straight through
      input_event = abs(Revdev::ABS_MT_POSITION_X, 480)
      expect(emulator.process(input_event)).to eq([input_event])
    end

    it "defers enabling until the frame boundary when called mid-frame" do
      touch_begin

      passthrough_event = abs(Revdev::ABS_MT_POSITION_X, 450)
      expect(emulator.process(passthrough_event)).to eq([passthrough_event])

      expect(emulator.set_scroll_mode(true)).to eq([])

      # The rest of the current frame still passes through untouched
      rest_event = abs(Revdev::ABS_MT_POSITION_Y, 520)
      expect(emulator.process(rest_event)).to eq([rest_event])
      syn_event = syn
      expect(emulator.process(syn_event)).to eq([syn_event])

      # From the next frame on, scroll mode is active
      output = process_frame(
        abs(Revdev::ABS_MT_POSITION_X, 470),
        abs(Revdev::ABS_MT_POSITION_Y, 540),
        syn
      )
      expect(tuples(output)).to include([Revdev::EV_ABS, Revdev::ABS_MT_SLOT, synthetic_slot])
      expect(tuples(output)).to include([Revdev::EV_KEY, Revdev::BTN_TOOL_DOUBLETAP, 1])
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
  end
end
