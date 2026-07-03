require "spec_helper"

require "fusuma/plugin/inputs/input"

require "fusuma/plugin/inputs/remap_keyboard_input"
require "fusuma/plugin/remap/scroll_channel"

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
      let(:record) { {"key" => "J", "status" => 1}.to_json + "\n" }

      it "returns an Event" do
        expect(instance.create_event(record: record)).to be_a_kind_of(Fusuma::Plugin::Events::Event)
      end
    end
  end

  describe "#setup_remapper" do
    let(:layer_manager) do
      instance_double(
        "Fusuma::Plugin::Remap::LayerManager",
        reader: double(close: nil),
        writer: double(close: nil)
      )
    end
    let(:scroll_channel) { instance_double("Fusuma::Plugin::Remap::ScrollChannel") }

    before do
      allow_any_instance_of(described_class).to receive(:fork).and_yield
      allow_any_instance_of(described_class).to receive(:config_params).and_return(nil)
      allow(IO).to receive(:pipe).and_return([double(close: nil), double(close: nil)])
      allow(Fusuma::Plugin::Remap::LayerManager).to receive(:instance).and_return(layer_manager)
      allow(Fusuma::Plugin::Remap::ScrollChannel).to receive(:instance).and_return(scroll_channel)
    end

    it "passes the pre-fork ScrollChannel singleton to KeyboardRemapper" do
      expect(Fusuma::Plugin::Remap::KeyboardRemapper).to receive(:new).with(
        hash_including(scroll_channel: scroll_channel)
      ).and_return(double(run: nil))

      described_class.new
    end
  end
end
