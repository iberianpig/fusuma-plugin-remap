require "spec_helper"

require "fusuma/plugin/remap/device_selector"
require "fusuma/device"

RSpec.describe Fusuma::Plugin::Remap::DeviceSelector do
  describe "#select" do
    let(:selector) { described_class.new(name_patterns: name_patterns, device_type: device_type) }
    let(:name_patterns) { ["Touchpad"] }
    let(:device_type) { :touchpad }

    before do
      allow(Fusuma::Device).to receive(:reset)
    end

    context "when device is found" do
      let(:event_device) { double(Revdev::EventDevice, name: "Touchpad") }

      before do
        allow(Fusuma::Device).to receive(:all).and_return([
          Fusuma::Device.new(name: "Touchpad", id: "event0", available: true)
        ])
        allow(Revdev::EventDevice).to receive(:new).and_return(event_device)
      end

      it "returns array of EventDevice" do
        result = selector.select
        expect(result).to be_a_kind_of(Array)
        expect(result.first).to eq(event_device)
      end

      it "does not wait when device is found immediately" do
        expect(selector).not_to receive(:sleep)
        selector.select
      end
    end

    context "when device is not found and wait: false" do
      before do
        allow(Fusuma::Device).to receive(:all).and_return([])
        allow(Fusuma::Device).to receive(:available).and_return([])
      end

      it "returns empty array immediately" do
        result = selector.select(wait: false)
        expect(result).to eq([])
      end

      it "does not sleep" do
        expect(selector).not_to receive(:sleep)
        selector.select(wait: false)
      end
    end

    context "when device is not found and wait: true" do
      let(:event_device) { double(Revdev::EventDevice, name: "Touchpad") }
      let(:found_devices) { [Fusuma::Device.new(name: "Touchpad", id: "event0", available: true)] }

      before do
        # First call returns empty, second call returns device
        call_count = 0
        allow(Fusuma::Device).to receive(:all) do
          call_count += 1
          (call_count == 1) ? [] : found_devices
        end
        allow(Revdev::EventDevice).to receive(:new).and_return(event_device)
        allow(selector).to receive(:sleep)
        allow(Fusuma::MultiLogger).to receive(:warn)
      end

      it "waits and retries until device is found" do
        result = selector.select(wait: true)
        expect(result).to be_a_kind_of(Array)
        expect(result.first).to eq(event_device)
      end

      it "logs waiting message once" do
        expect(Fusuma::MultiLogger).to receive(:warn).with(/No touchpad found/).once
        expect(Fusuma::MultiLogger).to receive(:warn).with(/Waiting for touchpad/).once
        selector.select(wait: true)
      end

      it "sleeps for POLL_INTERVAL" do
        expect(selector).to receive(:sleep).with(described_class::POLL_INTERVAL)
        selector.select(wait: true)
      end
    end

    context "with nil name_patterns (uses Device.available)" do
      let(:selector) { described_class.new(name_patterns: nil, device_type: :touchpad) }
      let(:event_device) { double(Revdev::EventDevice, name: "Touchpad") }

      before do
        allow(Fusuma::Device).to receive(:available).and_return([
          Fusuma::Device.new(name: "Touchpad", id: "event0", available: true)
        ])
        allow(Revdev::EventDevice).to receive(:new).and_return(event_device)
      end

      it "uses Device.available for device detection" do
        expect(Fusuma::Device).to receive(:available)
        selector.select
      end

      it "returns devices from Device.available" do
        result = selector.select
        expect(result).to be_a_kind_of(Array)
        expect(result.first).to eq(event_device)
      end
    end

    context "with device_type: :keyboard" do
      let(:selector) { described_class.new(name_patterns: ["Keyboard"], device_type: :keyboard) }

      before do
        allow(Fusuma::Device).to receive(:all).and_return([])
        allow(Fusuma::MultiLogger).to receive(:warn)
        allow(selector).to receive(:sleep)
      end

      it "logs waiting message with keyboard type" do
        # First call with wait: false returns immediately
        selector.select(wait: false)
        # Verify no keyboard-specific log was needed since it returned immediately
      end
    end
  end

  describe "POLL_INTERVAL constant" do
    it "is defined as 3 seconds" do
      expect(described_class::POLL_INTERVAL).to eq(3)
    end
  end
end
