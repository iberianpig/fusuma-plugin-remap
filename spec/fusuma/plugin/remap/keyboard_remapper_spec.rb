require "spec_helper"

require "fusuma/plugin/remap/keyboard_remapper"
require "fusuma/device"

RSpec.describe Fusuma::Plugin::Remap::KeyboardRemapper do
  describe "#initialize" do
    let(:layer_manager) { instance_double("Fusuma::Plugin::Remap::LayerManager") }
    let(:fusuma_writer) { double("fusuma_writer") }
    let(:config) { {emergency_ungrab_keys: "RIGHTCTRL+LEFTCTRL"} }
    let(:remapper) { described_class.new(layer_manager: layer_manager, fusuma_writer: fusuma_writer, config: config) }

    it "initializes with correct config parameters" do
      expect(remapper.instance_variable_get(:@config)).to include(emergency_ungrab_keys: "RIGHTCTRL+LEFTCTRL")
    end
  end

  describe "#run" do
    before do
      allow_any_instance_of(described_class).to receive(:create_virtual_keyboard)
      allow_any_instance_of(described_class).to receive(:grab_events)
    end
  end

  describe "key conversion methods" do
    let(:layer_manager) { instance_double("Fusuma::Plugin::Remap::LayerManager") }
    let(:fusuma_writer) { double("fusuma_writer") }
    let(:config) { {} }
    let(:remapper) { described_class.new(layer_manager: layer_manager, fusuma_writer: fusuma_writer, config: config) }

    describe "#code_to_key" do
      it "converts key codes to key names" do
        # KEY_A = 30, KEY_B = 48
        expect(remapper.send(:code_to_key, 30)).to eq("A")
        expect(remapper.send(:code_to_key, 48)).to eq("B")
      end

      it "converts BTN codes to BTN names" do
        # BTN_LEFT = 272
        expect(remapper.send(:code_to_key, 272)).to eq("BTN_LEFT")
      end

      it "returns nil for invalid codes" do
        expect(remapper.send(:code_to_key, 99999)).to be_nil
      end
    end

    describe "#key_to_code" do
      it "converts key names to key codes" do
        expect(remapper.send(:key_to_code, "A")).to eq(30)
        expect(remapper.send(:key_to_code, "B")).to eq(48)
      end

      it "converts BTN names to BTN codes" do
        expect(remapper.send(:key_to_code, "BTN_LEFT")).to eq(272)
      end

      it "handles lowercase key names" do
        expect(remapper.send(:key_to_code, "a")).to eq(30)
        expect(remapper.send(:key_to_code, "b")).to eq(48)
      end

      it "returns nil for invalid key names" do
        expect(remapper.send(:key_to_code, "INVALID_KEY")).to be_nil
      end
    end
  end

  describe "virtual key state management" do
    let(:layer_manager) { instance_double("Fusuma::Plugin::Remap::LayerManager") }
    let(:fusuma_writer) { double("fusuma_writer") }
    let(:config) { {} }
    let(:remapper) { described_class.new(layer_manager: layer_manager, fusuma_writer: fusuma_writer, config: config) }

    describe "#update_virtual_key_state" do
      it "adds key to pressed_virtual_keys on press event" do
        remapper.send(:update_virtual_key_state, "A", 1) # press
        expect(remapper.send(:pressed_virtual_keys)).to include("A")
      end

      it "removes key from pressed_virtual_keys on release event" do
        remapper.send(:update_virtual_key_state, "A", 1) # press
        remapper.send(:update_virtual_key_state, "A", 0) # release
        expect(remapper.send(:pressed_virtual_keys)).not_to include("A")
      end

      it "does not change state on repeat event" do
        remapper.send(:update_virtual_key_state, "A", 1) # press
        initial_state = remapper.send(:pressed_virtual_keys).dup
        remapper.send(:update_virtual_key_state, "A", 2) # repeat
        expect(remapper.send(:pressed_virtual_keys)).to eq(initial_state)
      end
    end

    describe "#should_use_original_key?" do
      it "returns false for press events" do
        expect(remapper.send(:should_use_original_key?, "A", 1)).to be false
      end

      it "returns false for repeat events" do
        expect(remapper.send(:should_use_original_key?, "A", 2)).to be false
      end

      it "returns false for release events of pressed keys" do
        remapper.send(:update_virtual_key_state, "A", 1) # press first
        expect(remapper.send(:should_use_original_key?, "A", 0)).to be false
      end

      it "returns true for release events of unpressed keys" do
        # Key was not pressed in virtual state (pressed before remapping started)
        expect(remapper.send(:should_use_original_key?, "A", 0)).to be true
      end
    end

    describe "#virtual_keyboard_all_key_released?" do
      it "returns true when no keys are pressed" do
        expect(remapper.send(:virtual_keyboard_all_key_released?)).to be true
      end

      it "returns false when keys are pressed" do
        remapper.send(:update_virtual_key_state, "A", 1) # press
        expect(remapper.send(:virtual_keyboard_all_key_released?)).to be false
      end

      it "returns true after all keys are released" do
        remapper.send(:update_virtual_key_state, "A", 1) # press
        remapper.send(:update_virtual_key_state, "B", 1) # press
        remapper.send(:update_virtual_key_state, "A", 0) # release
        expect(remapper.send(:virtual_keyboard_all_key_released?)).to be false
        remapper.send(:update_virtual_key_state, "B", 0) # release
        expect(remapper.send(:virtual_keyboard_all_key_released?)).to be true
      end
    end
  end

  describe "emergency keybind fallback" do
    let(:layer_manager) { instance_double("Fusuma::Plugin::Remap::LayerManager") }
    let(:fusuma_writer) { double("fusuma_writer") }
    let(:remapper) { described_class.new(layer_manager: layer_manager, fusuma_writer: fusuma_writer, config: config) }

    describe "#set_emergency_ungrab_keys" do
      context "with valid keybind (2 keys)" do
        let(:config) { {} }

        it "sets emergency keybind without warnings" do
          expect(Fusuma::MultiLogger).not_to receive(:warn)
          remapper.send(:set_emergency_ungrab_keys, "LEFTCTRL+RIGHTCTRL")
        end
      end

      context "with invalid keybind (1 key)" do
        let(:config) { {} }

        it "falls back to default keybind with warning" do
          expect(Fusuma::MultiLogger).to receive(:warn).with(/Invalid emergency ungrab keybinds/)
          expect(Fusuma::MultiLogger).to receive(:warn).with(/Please set two keys/)
          expect(Fusuma::MultiLogger).to receive(:warn).with(/plugin:/)
          expect(Fusuma::MultiLogger).to receive(:info).with(/Emergency ungrab keybind: RIGHTCTRL\+LEFTCTRL/)

          remapper.send(:set_emergency_ungrab_keys, "LEFTCTRL")
        end
      end

      context "with invalid keybind (3 keys)" do
        let(:config) { {} }

        it "falls back to default keybind with warning" do
          expect(Fusuma::MultiLogger).to receive(:warn).with(/Invalid emergency ungrab keybinds/)
          expect(Fusuma::MultiLogger).to receive(:warn).with(/Please set two keys/)
          expect(Fusuma::MultiLogger).to receive(:warn).with(/plugin:/)
          expect(Fusuma::MultiLogger).to receive(:info).with(/Emergency ungrab keybind: RIGHTCTRL\+LEFTCTRL/)

          remapper.send(:set_emergency_ungrab_keys, "LEFTCTRL+RIGHTCTRL+LEFTALT")
        end
      end

      context "with nil keybind" do
        let(:config) { {} }

        it "falls back to default keybind with warning" do
          expect(Fusuma::MultiLogger).to receive(:warn).with(/Invalid emergency ungrab keybinds/)
          expect(Fusuma::MultiLogger).to receive(:warn).with(/Please set two keys/)
          expect(Fusuma::MultiLogger).to receive(:warn).with(/plugin:/)
          expect(Fusuma::MultiLogger).to receive(:info).with(/Emergency ungrab keybind: RIGHTCTRL\+LEFTCTRL/)

          remapper.send(:set_emergency_ungrab_keys, nil)
        end
      end
    end
  end

  describe Fusuma::Plugin::Remap::KeyboardRemapper::KeyboardSelector do
    describe "#select" do
      let(:selector) { described_class.new(["dummy_valid_device"]) }
      let(:event_device) { double(Revdev::EventDevice, name: "dummy_valid_device") }

      context "with find devices" do
        before do
          allow(Fusuma::Device).to receive(:all).and_return([
            Fusuma::Device.new(name: "dummy_valid_device", id: "dummy"),
            Fusuma::Device.new(name: "dummy_virtual_keyboard", id: "dummy-virtual")
          ])
          allow(Revdev::EventDevice).to receive(:new).and_return(event_device)
        end

        it "should be Array of Revdev::EventDevice" do
          expect(selector.select).to be_a_kind_of(Array)
          expect(selector.select.first).to eq(event_device)
        end

        it "should except virtual devices" do
          stub_const("Fusuma::Plugin::Remap::KeyboardRemapper::VIRTUAL_KEYBOARD_NAME", "dummy_virtual_keyboard")
          expect(selector.select.map(&:name)).not_to include("dummy_virtual_keyboard")
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

  describe Fusuma::Plugin::Remap::KeyboardRemapper::TouchpadSelector do
    describe "#select" do
      context "with touchpad found" do
        let(:selector) { described_class.new(["Touchpad"]) }
        let(:event_device) { double(Revdev::EventDevice, name: "Touchpad") }

        before do
          allow(Fusuma::Device).to receive(:all).and_return([
            Fusuma::Device.new(name: "Touchpad", id: "event0", available: true)
          ])
          allow(Revdev::EventDevice).to receive(:new).and_return(event_device)
        end

        it "returns array of EventDevice" do
          expect(selector.select).to be_a_kind_of(Array)
          expect(selector.select.first).to eq(event_device)
        end
      end

      context "without touchpad (no device found)" do
        let(:selector) { described_class.new(["Touchpad"]) }

        before do
          allow(Fusuma::Device).to receive(:all).and_return([])
          allow(Fusuma::Device).to receive(:available).and_return([])
        end

        it "returns empty array without exit" do
          expect(selector.select).to eq([])
        end
      end

      context "with nil names (uses Device.available)" do
        let(:selector) { described_class.new(nil) }

        before do
          allow(Fusuma::Device).to receive(:available).and_return([])
        end

        it "returns empty array when no touchpad available" do
          expect(selector.select).to eq([])
        end
      end
    end
  end

  describe "#create_virtual_keyboard" do
    let(:layer_manager) { instance_double("Fusuma::Plugin::Remap::LayerManager") }
    let(:fusuma_writer) { double("fusuma_writer") }
    let(:uinput_keyboard) { instance_double("Fusuma::Plugin::Remap::UinputKeyboard") }

    context "with touchpad found" do
      let(:config) { {touchpad_name_patterns: ["Touchpad"]} }
      let(:remapper) { described_class.new(layer_manager: layer_manager, fusuma_writer: fusuma_writer, config: config) }
      let(:device_id) { double("device_id", vendor: 0x1234, product: 0x5678, version: 1) }
      let(:event_device) { double(Revdev::EventDevice, device_id: device_id) }

      before do
        allow(remapper).to receive(:uinput_keyboard).and_return(uinput_keyboard)
        allow(Fusuma::Device).to receive(:all).and_return([
          Fusuma::Device.new(name: "Touchpad", id: "event0", available: true)
        ])
        allow(Revdev::EventDevice).to receive(:new).and_return(event_device)
      end

      it "creates virtual keyboard with touchpad device ID" do
        expect(uinput_keyboard).to receive(:create).with(
          described_class::VIRTUAL_KEYBOARD_NAME,
          instance_of(Revdev::InputId)
        )
        remapper.send(:create_virtual_keyboard)
      end
    end

    context "without touchpad" do
      let(:config) { {touchpad_name_patterns: ["Touchpad"]} }
      let(:remapper) { described_class.new(layer_manager: layer_manager, fusuma_writer: fusuma_writer, config: config) }

      before do
        allow(remapper).to receive(:uinput_keyboard).and_return(uinput_keyboard)
        allow(Fusuma::Device).to receive(:all).and_return([])
        allow(Fusuma::Device).to receive(:available).and_return([])
      end

      it "creates virtual keyboard without device ID and logs warning" do
        expect(Fusuma::MultiLogger).to receive(:info).with(/Create virtual keyboard/)
        expect(Fusuma::MultiLogger).to receive(:warn).with(/No touchpad found/)
        expect(Fusuma::MultiLogger).to receive(:warn).with(/Disable-while-typing/)
        expect(uinput_keyboard).to receive(:create).with(described_class::VIRTUAL_KEYBOARD_NAME)
        remapper.send(:create_virtual_keyboard)
      end

      it "does not exit when touchpad is not found" do
        allow(Fusuma::MultiLogger).to receive(:info)
        allow(Fusuma::MultiLogger).to receive(:warn)
        allow(uinput_keyboard).to receive(:create)

        expect { remapper.send(:create_virtual_keyboard) }.not_to raise_error
      end
    end
  end
end
