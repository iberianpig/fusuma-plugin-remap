require "spec_helper"

require "fusuma/plugin/inputs/input"
require "fusuma/plugin/inputs/remap_touchpad_input"
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
        allow_any_instance_of(described_class::TouchpadSelector).to receive(:select).and_return([])
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
        allow_any_instance_of(described_class::TouchpadSelector).to receive(:select).and_return([])
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
        allow_any_instance_of(described_class::TouchpadSelector).to receive(:select).and_return([])
      end

      it "passes touchpad_name_patterns to TouchpadRemapper" do
        expect(Fusuma::Plugin::Remap::TouchpadRemapper).to receive(:new).with(
          hash_including(touchpad_name_patterns: touchpad_name_patterns)
        ).and_return(double(run: nil))

        described_class.new
      end
    end

    describe "non-blocking behavior" do
      it "TouchpadSelector.select is called inside fork (not blocking main process)" do
        touchpad_selector_called_in_fork = false

        allow_any_instance_of(described_class).to receive(:fork) do |&block|
          # Simulate fork - TouchpadSelector should be called inside this block
          allow_any_instance_of(described_class::TouchpadSelector).to receive(:select) do
            touchpad_selector_called_in_fork = true
            []
          end
          block&.call
        end
        allow(IO).to receive(:pipe).and_return([double(close: nil), double(close: nil)])
        allow(Fusuma::Plugin::Remap::TouchpadRemapper).to receive(:new).and_return(double(run: nil))

        described_class.new

        expect(touchpad_selector_called_in_fork).to be true
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

  describe described_class::TouchpadSelector do
    describe "#select" do
      context "with touchpads found" do
        let(:selector) { described_class.new(["Touchpad"]) }
        let(:event_device) { double(Revdev::EventDevice, name: "Touchpad") }

        before do
          allow(Fusuma::Device).to receive(:reset)
          allow(Fusuma::Device).to receive(:all).and_return([
            Fusuma::Device.new(name: "My Touchpad", id: "event0", available: true)
          ])
          allow(Revdev::EventDevice).to receive(:new).and_return(event_device)
        end

        it "returns array of EventDevice" do
          expect(selector.select).to be_a_kind_of(Array)
          expect(selector.select.first).to eq(event_device)
        end

        it "calls Device.reset to refresh cache" do
          expect(Fusuma::Device).to receive(:reset)
          selector.select
        end
      end

      context "without touchpad found (waits for connection)" do
        let(:selector) { described_class.new(["Touchpad"]) }
        let(:event_device) { double(Revdev::EventDevice, name: "Touchpad") }

        before do
          allow(Fusuma::Device).to receive(:reset)
        end

        it "waits and retries until touchpad is found" do
          call_count = 0
          allow(Fusuma::Device).to receive(:all) do
            call_count += 1
            if call_count < 3
              []
            else
              [Fusuma::Device.new(name: "Touchpad", id: "event0")]
            end
          end
          allow(selector).to receive(:wait_for_device)
          allow(Revdev::EventDevice).to receive(:new).and_return(event_device)

          expect(selector).to receive(:wait_for_device).exactly(2).times
          selector.select
        end

        it "logs warning when no touchpad found" do
          call_count = 0
          allow(Fusuma::Device).to receive(:all) do
            call_count += 1
            if call_count == 1
              []
            else
              [Fusuma::Device.new(name: "Touchpad", id: "event0")]
            end
          end
          allow(selector).to receive(:wait_for_device)
          allow(Revdev::EventDevice).to receive(:new).and_return(event_device)

          expect(Fusuma::MultiLogger).to receive(:warn).with(/No touchpad found/)
          expect(Fusuma::MultiLogger).to receive(:warn).with(/Waiting for touchpad/)
          selector.select
        end

        it "logs warning only once" do
          call_count = 0
          allow(Fusuma::Device).to receive(:all) do
            call_count += 1
            if call_count < 4
              []
            else
              [Fusuma::Device.new(name: "Touchpad", id: "event0")]
            end
          end
          allow(selector).to receive(:wait_for_device)
          allow(Revdev::EventDevice).to receive(:new).and_return(event_device)

          expect(Fusuma::MultiLogger).to receive(:warn).with(/No touchpad found/).once
          expect(Fusuma::MultiLogger).to receive(:warn).with(/Waiting for touchpad/).once
          selector.select
        end
      end

      context "with nil names (uses Device.available)" do
        let(:selector) { described_class.new(nil) }
        let(:event_device) { double(Revdev::EventDevice, name: "Touchpad") }

        before do
          allow(Fusuma::Device).to receive(:reset)
          allow(Fusuma::Device).to receive(:available).and_return([
            Fusuma::Device.new(name: "Touchpad", id: "event0")
          ])
          allow(Revdev::EventDevice).to receive(:new).and_return(event_device)
        end

        it "uses Device.available instead of filtering by name" do
          expect(Fusuma::Device).to receive(:available)
          selector.select
        end

        it "returns array of EventDevice" do
          expect(selector.select).to be_a_kind_of(Array)
          expect(selector.select.first).to eq(event_device)
        end
      end

      context "with name patterns array" do
        let(:selector) { described_class.new(["Touchpad", "SynPS/2"]) }
        let(:event_device) { double(Revdev::EventDevice, name: "SynPS/2 Touchpad") }

        before do
          allow(Fusuma::Device).to receive(:reset)
          allow(Fusuma::Device).to receive(:all).and_return([
            Fusuma::Device.new(name: "SynPS/2 Synaptics TouchPad", id: "event0"),
            Fusuma::Device.new(name: "Keyboard", id: "event1")
          ])
          allow(Revdev::EventDevice).to receive(:new).and_return(event_device)
        end

        it "filters devices matching any pattern" do
          result = selector.select
          expect(result).to be_a_kind_of(Array)
          expect(result.size).to eq(1)
        end
      end
    end

    describe "#wait_for_device" do
      let(:selector) { described_class.new(nil) }

      it "sleeps for 3 seconds" do
        expect(selector).to receive(:sleep).with(3)
        selector.wait_for_device
      end
    end
  end
end
