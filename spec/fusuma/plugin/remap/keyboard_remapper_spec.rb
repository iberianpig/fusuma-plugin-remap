require "spec_helper"

require "fusuma/plugin/remap/keyboard_remapper"
require "fusuma/device"

RSpec.describe Fusuma::Plugin::Remap::KeyboardRemapper do
  describe "#initialize" do
  end

  describe "#run" do
    before do
      allow_any_instance_of(described_class).to receive(:create_virtual_keyboard)
      allow_any_instance_of(described_class).to receive(:grab_events)
    end
  end

  describe Fusuma::Plugin::Remap::KeyboardRemapper::KeyboardSelector do
    describe "#select" do
      let(:selector) { described_class.new(["dummy_valid_device"]) }
      let(:event_device) { double(Revdev::EventDevice) }

      context "with find devices" do
        before do
          allow(Fusuma::Device).to receive(:all).and_return([Fusuma::Device.new(name: "dummy_valid_device", id: "dummy")])
          allow(Revdev::EventDevice).to receive(:new).and_return(event_device)
        end
        it "should be Array of Revdev::EventDevice" do
          expect(selector.select).to be_a_kind_of(Array)
          expect(selector.select.first).to eq(event_device)
        end
      end

      context "without find device" do
        before do
          allow(selector).to receive(:loop).and_yield
          allow(Fusuma::Device).to receive(:all).and_return([])
        end

        it "wait for device, and logs warn message" do
          expect(selector).to receive(:wait_for_device)
          expect(Fusuma::MultiLogger).to receive(:warn).with(/No keyboard found/)
          selector.select
        end
      end
    end
  end
end
