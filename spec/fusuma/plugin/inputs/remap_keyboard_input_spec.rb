require "spec_helper"

require "fusuma/plugin/inputs/input"

require "fusuma/plugin/inputs/remap_keyboard_input"

# require "fusuma/plugin/events/records/keypress_record"

RSpec.describe Fusuma::Plugin::Inputs::RemapKeyboardInput do
  describe "#initialize" do
    it "calls setup_remapper" do
      expect_any_instance_of(described_class).to receive(:setup_remapper)
      described_class.new
    end
  end

  describe "#create_event" do
    before do
      allow_any_instance_of(described_class).to receive(:setup_remapper)
    end
    let(:instance) { described_class.new }

    context "with valid record" do
      let(:record) { MessagePack.pack({"key" => "J", "status" => 1}) }

      it "returns an Event" do
        expect(instance.create_event(record: record)).to be_a_kind_of(Fusuma::Plugin::Events::Event)
      end
    end
  end
end
