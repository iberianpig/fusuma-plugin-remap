# frozen_string_literal: true

require "spec_helper"
require "map_entry"
require "remap_core"

RSpec.describe RemapCore do
  let(:core) { described_class.new }
  let(:device) { "HHKB" }

  def update_mapping(entries, layer: "{}")
    core.update_mapping(device, layer, entries)
  end

  def process(code, value)
    core.process(device, 1, code, value)
  end

  def emit_codes(result)
    result.events
      .reject(&:empty?)
      .map { |event| event.split(",").map(&:to_i) }
  end

  it "simple-remaps press and release consistently" do
    update_mapping({"CAPSLOCK" => MapEntry.new("simple", ["LEFTCTRL"])})

    press = process(58, 1)
    release = process(58, 0)

    expect(emit_codes(press)).to eq([[1, 29, 1]])
    expect(emit_codes(release)).to eq([[1, 29, 0]])
    expect(press.lines.first).to include('"key":"CAPSLOCK"')
  end

  it "sends modifier combos with temporary modifier release" do
    update_mapping(
      {
        "CAPSLOCK" => MapEntry.new("simple", ["LEFTCTRL"]),
        "LEFTCTRL+A" => MapEntry.new("combo", ["HOME"])
      }
    )

    process(58, 1)
    result = process(30, 1)

    expect(emit_codes(result)).to eq([
      [1, 29, 0],
      [1, 102, 1],
      [1, 102, 0],
      [1, 29, 1]
    ])
  end

  it "sends output sequences in order without Array#reverse" do
    update_mapping({"X" => MapEntry.new("seq", ["LEFTSHIFT+HOME", "DELETE"])})

    result = process(45, 1)

    expect(emit_codes(result)).to eq([
      [1, 42, 1],
      [1, 102, 1],
      [1, 102, 0],
      [1, 42, 0],
      [1, 111, 1],
      [1, 111, 0]
    ])
  end

  it "swallows command mappings after reporting the source key" do
    update_mapping({"Y" => MapEntry.new("swallow", [])}, layer: '{"thumbsense":true}')

    result = process(21, 1)

    expect(emit_codes(result)).to be_empty
    expect(result.lines).to eq(['{"t":"key","key":"Y","status":1,"layer":{"thumbsense":true}}'])
  end

  it "keeps old simple mapping until pressed virtual keys are released" do
    update_mapping({"A" => MapEntry.new("simple", ["B"])})
    press = process(30, 1)

    update_mapping({"A" => MapEntry.new("simple", ["C"])})
    release = process(30, 0)
    next_press = process(30, 1)

    expect(emit_codes(press)).to eq([[1, 48, 1]])
    expect(emit_codes(release)).to eq([[1, 48, 0]])
    expect(emit_codes(next_press)).to eq([[1, 46, 1]])
  end
end
