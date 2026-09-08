# frozen_string_literal: true

require "spec_helper"
require "fusuma/plugin/remap/uinput_touchpad"

RSpec.describe UinputTouchpad do
  let(:file) { double("uinput file", syswrite: nil) }
  let(:ioctls) { [] }
  let(:uinput) do
    described_class.allocate.tap do |device|
      device.instance_variable_set(:@file, file)
      device.instance_variable_set(:@is_created, false)
    end
  end
  let(:device_id) { double("InputId", vendor: 0x1234, product: 0x5678, version: 1) }
  let(:source_device) { double("Revdev::EventDevice", device_id: device_id) }
  let(:absinfo) { {absmin: 0, absmax: 1000, absfuzz: 0, absflat: 0, resolution: 1} }

  before do
    allow(file).to receive(:ioctl) do |request, argument|
      ioctls << [request, argument]
      0
    end
    allow(source_device).to receive(:absinfo_for_axis).and_return(absinfo)
    allow(source_device).to receive(:read_ioctl_with) do |request|
      case request & 0xff
      when 0x20
        bit_string([Revdev::EV_KEY, Revdev::EV_ABS, Revdev::EV_REL, Revdev::EV_MSC], Revdev::EV_CNT)
      when 0x20 + Revdev::EV_KEY
        bit_string([Revdev::BTN_LEFT, Revdev::BTN_TOUCH, Revdev::BTN_TOOL_FINGER], Revdev::KEY_CNT)
      when 0x20 + Revdev::EV_ABS
        bit_string([
          Revdev::ABS_X,
          Revdev::ABS_Y,
          Revdev::ABS_MT_SLOT,
          Revdev::ABS_MT_POSITION_X,
          Revdev::ABS_MT_POSITION_Y,
          Revdev::ABS_MT_TRACKING_ID,
          Revdev::ABS_MT_PRESSURE
        ], Revdev::ABS_CNT)
      when 0x20 + Revdev::EV_REL
        bit_string([Revdev::REL_X], Revdev::REL_CNT)
      when 0x20 + Revdev::EV_MSC
        bit_string([0x05], Revdev::MSC_CNT)
      when 0x09
        bit_string([Revdev::INPUT_PROP_POINTER, Revdev::INPUT_PROP_BUTTONPAD], Revdev::INPUT_PROP_CNT)
      else
        "".b
      end
    end
  end

  def bit_string(bits, max)
    bytes = Array.new((max + 7) / 8, 0)
    bits.each { |bit| bytes[bit / 8] |= (1 << (bit % 8)) }
    bytes.pack("C*")
  end

  describe "#create_from_device" do
    it "sets only key bits supported by the source device" do
      uinput.create_from_device(name: "fusuma_virtual_touchpad", device: source_device)

      expect(ioctls).to include([Ruinput::UI_SET_KEYBIT, Revdev::BTN_LEFT])
      expect(ioctls).to include([Ruinput::UI_SET_KEYBIT, Revdev::BTN_TOUCH])
      expect(ioctls).not_to include([Ruinput::UI_SET_KEYBIT, Revdev::BTN_RIGHT])
    end

    it "sets all supported absolute axes including pressure-like axes" do
      uinput.create_from_device(name: "fusuma_virtual_touchpad", device: source_device)

      expect(ioctls).to include([Ruinput::UI_SET_ABSBIT, Revdev::ABS_MT_POSITION_X])
      expect(ioctls).to include([Ruinput::UI_SET_ABSBIT, Revdev::ABS_MT_PRESSURE])
    end

    it "copies relative, MSC, and input property bits from the source device" do
      uinput.create_from_device(name: "fusuma_virtual_touchpad", device: source_device)

      expect(ioctls).to include([Ruinput::UI_SET_RELBIT, Revdev::REL_X])
      expect(ioctls).to include([Ruinput::UI_SET_MSCBIT, 0x05])
      expect(ioctls).to include([Ruinput::UI_SET_PROPBIT, Revdev::INPUT_PROP_POINTER])
      expect(ioctls).to include([Ruinput::UI_SET_PROPBIT, Revdev::INPUT_PROP_BUTTONPAD])
    end

    it "falls back to static event setup when capability probing returns no events" do
      allow(uinput).to receive(:supported_capabilities).and_return(
        events: [],
        keys: [],
        abs: [],
        rels: [],
        mscs: [],
        props: []
      )

      expect(Fusuma::MultiLogger).to receive(:warn).with(/Failed to probe touchpad capabilities/)
      expect(uinput).to receive(:set_all_events)

      uinput.create_from_device(name: "fusuma_virtual_touchpad", device: source_device)
    end
  end
end
