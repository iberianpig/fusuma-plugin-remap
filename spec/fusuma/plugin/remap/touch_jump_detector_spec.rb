# frozen_string_literal: true

require "spec_helper"
require "fusuma/plugin/remap/touch_jump_detector"

RSpec.describe Fusuma::Plugin::Remap::TouchJumpDetector do
  let(:device) { double("Revdev::EventDevice") }
  let(:detector) { described_class.new(device: device) }

  before do
    allow(device).to receive(:absinfo_for_axis).with(Revdev::ABS_MT_POSITION_X).and_return(absmin: 0, absmax: 1000)
    allow(device).to receive(:absinfo_for_axis).with(Revdev::ABS_MT_POSITION_Y).and_return(absmin: 0, absmax: 1000)
  end

  def event(type, code, value)
    Revdev::InputEvent.new(nil, type, code, value)
  end

  def abs(code, value)
    event(Revdev::EV_ABS, code, value)
  end

  def syn
    event(Revdev::EV_SYN, Revdev::SYN_REPORT, 0)
  end

  def observe_frame(*events)
    events.each { |input_event| detector.observe(input_event) }
    detector.observe(syn)
  end

  def touch_begin(slot: 0, tracking_id: 10, x: 400, y: 500)
    observe_frame(
      abs(Revdev::ABS_MT_SLOT, slot),
      abs(Revdev::ABS_MT_TRACKING_ID, tracking_id),
      abs(Revdev::ABS_MT_POSITION_X, x),
      abs(Revdev::ABS_MT_POSITION_Y, y)
    )
  end

  it "warns when an active touch moves beyond the jump threshold within one frame" do
    touch_begin(slot: 0, tracking_id: 10, x: 400, y: 500)

    expect(Fusuma::MultiLogger).to receive(:warn).with(a_string_matching(/TouchJumpDetector.*slot=0.*tracking_id=10.*x:400->600/))

    observe_frame(abs(Revdev::ABS_MT_POSITION_X, 600))
  end

  it "does not warn when an active touch moves less than the jump threshold" do
    touch_begin(slot: 0, tracking_id: 10, x: 400, y: 500)

    expect(Fusuma::MultiLogger).not_to receive(:warn)

    observe_frame(
      abs(Revdev::ABS_MT_POSITION_X, 450),
      abs(Revdev::ABS_MT_POSITION_Y, 550)
    )
  end

  it "does not warn when a new touch lands far from the previously released position" do
    touch_begin(slot: 0, tracking_id: 10, x: 400, y: 500)
    observe_frame(abs(Revdev::ABS_MT_TRACKING_ID, -1))

    expect(Fusuma::MultiLogger).not_to receive(:warn)

    touch_begin(slot: 0, tracking_id: 11, x: 900, y: 100)
  end

  it "includes the offending frame contents in the warning" do
    touch_begin(slot: 0, tracking_id: 10, x: 400, y: 500)

    expected_frame = "frame=[[#{Revdev::EV_ABS}, #{Revdev::ABS_MT_POSITION_X}, 600]]"
    expect(Fusuma::MultiLogger).to receive(:warn).with(a_string_including(expected_frame))

    observe_frame(abs(Revdev::ABS_MT_POSITION_X, 600))
  end

  describe "stall detection" do
    let(:clock) { double("clock") }
    let(:detector) { described_class.new(device: device, clock: -> { clock.now }) }

    it "does not warn when events arrive within the stall threshold" do
      allow(clock).to receive(:now).and_return(0.0, 0.01, 0.06)

      detector.observe(abs(Revdev::ABS_MT_TRACKING_ID, 10))
      detector.observe(syn)

      expect(Fusuma::MultiLogger).not_to receive(:warn)

      detector.observe(abs(Revdev::ABS_MT_POSITION_X, 401))
    end

    it "does not warn for the idle gap between two separate touches" do
      # touch-down+release, then a long idle, then the next touch-down
      allow(clock).to receive(:now).and_return(0.0, 0.0, 0.01, 0.01, 5.0, 5.0)
      expect(Fusuma::MultiLogger).not_to receive(:warn)

      detector.observe(abs(Revdev::ABS_MT_TRACKING_ID, 10))
      detector.observe(syn)
      detector.observe(abs(Revdev::ABS_MT_TRACKING_ID, -1))
      detector.observe(syn)
      detector.observe(abs(Revdev::ABS_MT_TRACKING_ID, 11))
      detector.observe(syn)
    end

    it "warns for a stall that happens while a touch is active" do
      allow(clock).to receive(:now).and_return(0.0, 0.0, 0.5)

      detector.observe(abs(Revdev::ABS_MT_TRACKING_ID, 10))
      detector.observe(syn)

      expect(Fusuma::MultiLogger).to receive(:warn).with(a_string_matching(/stall.*500ms/))

      detector.observe(abs(Revdev::ABS_MT_POSITION_X, 401))
    end
  end
end
