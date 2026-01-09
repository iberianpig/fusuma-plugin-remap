require "spec_helper"

require "fusuma/plugin/inputs/input"
require "fusuma/plugin/inputs/remap_touchpad_input"
require "fusuma/plugin/remap/device_selector"
require "fusuma/device"

RSpec.describe Fusuma::Plugin::Inputs::RemapTouchpadInput do
  describe "#initialize" do
    before do
      allow_any_instance_of(described_class).to receive(:setup_remapper)
    end

    it "calls setup_remapper" do
      expect_any_instance_of(described_class).to receive(:setup_remapper)
      described_class.new
    end
  end

  describe "#setup_remapper" do
    before do
      allow_any_instance_of(described_class).to receive(:fork).and_yield
      allow_any_instance_of(described_class).to receive(:config_params).and_return(nil)
    end

    describe "IO pipe creation" do
      it "creates IO pipe before fork" do
        pipes_created = false
        allow(IO).to receive(:pipe) do
          pipes_created = true
          [instance_double("IO", close: nil), instance_double("IO", close: nil)]
        end
        allow_any_instance_of(Fusuma::Plugin::Remap::DeviceSelector).to receive(:select).and_return([])
        allow(Fusuma::Plugin::Remap::TouchpadRemapper).to receive(:new).and_return(double(run: nil))

        described_class.new

        expect(pipes_created).to be true
      end
    end

    describe "fork process" do
      it "forks a child process" do
        fork_called = false
        allow_any_instance_of(described_class).to receive(:fork) do |&block|
          fork_called = true
          block&.call
        end
        allow(IO).to receive(:pipe).and_return([double(close: nil), double(close: nil)])
        allow_any_instance_of(Fusuma::Plugin::Remap::DeviceSelector).to receive(:select).and_return([])
        allow(Fusuma::Plugin::Remap::TouchpadRemapper).to receive(:new).and_return(double(run: nil))

        described_class.new

        expect(fork_called).to be true
      end
    end

    describe "touchpad_name_patterns passing" do
      let(:touchpad_name_patterns) { ["Touchpad", "SynPS/2"] }

      before do
        allow_any_instance_of(described_class).to receive(:config_params).with(:touchpad_name_patterns).and_return(touchpad_name_patterns)
        allow(IO).to receive(:pipe).and_return([double(close: nil), double(close: nil)])
        allow_any_instance_of(Fusuma::Plugin::Remap::DeviceSelector).to receive(:select).and_return([])
      end

      it "passes touchpad_name_patterns to TouchpadRemapper" do
        expect(Fusuma::Plugin::Remap::TouchpadRemapper).to receive(:new).with(
          hash_including(touchpad_name_patterns: touchpad_name_patterns)
        ).and_return(double(run: nil))

        described_class.new
      end
    end

    describe "non-blocking behavior" do
      it "DeviceSelector.select is called inside fork (not blocking main process)" do
        device_selector_called_in_fork = false

        allow_any_instance_of(described_class).to receive(:fork) do |&block|
          # Simulate fork - DeviceSelector should be called inside this block
          allow_any_instance_of(Fusuma::Plugin::Remap::DeviceSelector).to receive(:select) do
            device_selector_called_in_fork = true
            []
          end
          block&.call
        end
        allow(IO).to receive(:pipe).and_return([double(close: nil), double(close: nil)])
        allow(Fusuma::Plugin::Remap::TouchpadRemapper).to receive(:new).and_return(double(run: nil))

        described_class.new

        expect(device_selector_called_in_fork).to be true
      end
    end
  end

  describe "#read_from_io" do
    let(:fusuma_reader) { StringIO.new }

    before do
      allow_any_instance_of(described_class).to receive(:setup_remapper)
    end

    let(:instance) do
      input = described_class.new
      input.instance_variable_set(:@fusuma_reader, fusuma_reader)
      input
    end

    context "with valid gesture record" do
      before do
        data = {"finger" => 2, "status" => "begin"}.to_msgpack
        fusuma_reader.write(data)
        fusuma_reader.rewind
      end

      it "returns a GestureRecord" do
        record = instance.read_from_io
        expect(record).to be_a(Fusuma::Plugin::Events::Records::GestureRecord)
      end

      it "extracts finger count from data" do
        record = instance.read_from_io
        expect(record.finger).to eq(2)
      end

      it "extracts status from data" do
        record = instance.read_from_io
        expect(record.status).to eq("begin")
      end

      it "sets gesture type to 'touch'" do
        record = instance.read_from_io
        expect(record.gesture).to eq("touch")
      end
    end
  end
end
