# frozen_string_literal: true

require "spec_helper"
require "control_parser"

RSpec.describe ControlParser do
  let(:parser) { described_class.new }

  it "parses config messages" do
    msg = parser.parse(
      '{"t":"config","emergency":["RIGHTCTRL","LEFTCTRL"],"vname":"fusuma_virtual_keyboard","bustype":17,"vendor":1,"product":2,"version":3}'
    )

    expect(msg.type).to eq("config")
    expect(msg.emergency).to eq(%w[RIGHTCTRL LEFTCTRL])
    expect(msg.vname).to eq("fusuma_virtual_keyboard")
    expect(msg.bustype).to eq(17)
    expect(msg.vendor).to eq(1)
    expect(msg.product).to eq(2)
    expect(msg.version).to eq(3)
  end

  it "parses mapping messages with escaped layer tokens" do
    msg = parser.parse(
      '{"t":"mapping","device":"HHKB","layer":"{\"thumbsense\":true}","entries":[["CAPSLOCK","simple","LEFTCTRL"],["LEFTCTRL+A","combo","HOME"],["X","seq","LEFTSHIFT+HOME|DELETE"],["Y","swallow",""]]}'
    )

    expect(msg.type).to eq("mapping")
    expect(msg.device).to eq("HHKB")
    expect(msg.layer_token).to eq('{"thumbsense":true}')
    expect(msg.entries["CAPSLOCK"].kind).to eq("simple")
    expect(msg.entries["CAPSLOCK"].to).to eq(["LEFTCTRL"])
    expect(msg.entries["X"].to).to eq(["LEFTSHIFT+HOME", "DELETE"])
    expect(msg.entries["Y"].to).to eq([])
  end

  it "parses golden event messages" do
    msg = parser.parse('{"t":"event","etype":1,"code":30,"value":1}')

    expect(msg.type).to eq("event")
    expect(msg.event_type).to eq(1)
    expect(msg.code).to eq(30)
    expect(msg.value).to eq(1)
  end
end
