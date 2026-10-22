require "spec_helper"
require "stringio"

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
      let(:record) { {"key" => "J", "status" => 1}.to_json + "\n" }

      it "returns an Event" do
        expect(instance.create_event(record: record)).to be_a_kind_of(Fusuma::Plugin::Events::Event)
      end
    end
  end

  describe "#read_from_io" do
    before do
      allow_any_instance_of(described_class).to receive(:setup_remapper)
    end

    let(:reader) { StringIO.new(input) }
    let(:instance) do
      described_class.new.tap do |plugin|
        plugin.instance_variable_set(:@fusuma_reader, reader)
      end
    end

    context "with a key event" do
      let(:input) do
        {t: "key", key: "A", status: 1, layer: {"thumbsense" => true}}.to_json + "\n"
      end

      it "returns a keypress record" do
        record = instance.read_from_io

        expect(record.status).to eq("pressed")
        expect(record.code).to eq("A")
        expect(record.layer).to eq("thumbsense" => true)
      end

      it "returns a record accepted by Input#create_event" do
        event = instance.create_event(record: instance.read_from_io)

        expect(event).to be_a_kind_of(Fusuma::Plugin::Events::Event)
      end
    end
  end
end
