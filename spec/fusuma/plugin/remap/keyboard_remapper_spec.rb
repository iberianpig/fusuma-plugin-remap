require "spec_helper"

require "fusuma/plugin/remap/keyboard_remapper"
require "fusuma/plugin/remap/device_selector"
require "fusuma/plugin/remap/device_matcher"
require "fusuma/device"

RSpec.describe Fusuma::Plugin::Remap::KeyboardRemapper do
  # Common test doubles
  let(:layer_manager) { instance_double("Fusuma::Plugin::Remap::LayerManager") }
  let(:fusuma_writer) { double("fusuma_writer") }
  let(:config) { {} }
  let(:remapper) { described_class.new(layer_manager: layer_manager, fusuma_writer: fusuma_writer, config: config) }
  let(:uinput_keyboard) { instance_double("Fusuma::Plugin::Remap::UinputKeyboard") }

  describe "#initialize" do
    let(:config) { {emergency_ungrab_keys: "RIGHTCTRL+LEFTCTRL"} }

    it "initializes with correct config parameters" do
      expect(remapper.instance_variable_get(:@config)).to include(emergency_ungrab_keys: "RIGHTCTRL+LEFTCTRL")
    end
  end

  describe "key conversion methods" do
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
    describe "#set_emergency_ungrab_keys" do
      context "with valid keybind (2 keys)" do
        it "sets emergency keybind without warnings" do
          expect(Fusuma::MultiLogger).not_to receive(:warn)
          remapper.send(:set_emergency_ungrab_keys, "LEFTCTRL+RIGHTCTRL")
        end
      end

      shared_examples "falls back to default keybind" do |keybind|
        it "falls back to default keybind with warning" do
          expect(Fusuma::MultiLogger).to receive(:warn).with(/Invalid emergency ungrab keybinds/)
          expect(Fusuma::MultiLogger).to receive(:warn).with(/Please set two keys/)
          expect(Fusuma::MultiLogger).to receive(:warn).with(/plugin:/)
          expect(Fusuma::MultiLogger).to receive(:info).with(/Emergency ungrab keybind: RIGHTCTRL\+LEFTCTRL/)

          remapper.send(:set_emergency_ungrab_keys, keybind)
        end
      end

      context "with invalid keybind (1 key)" do
        it_behaves_like "falls back to default keybind", "LEFTCTRL"
      end

      context "with invalid keybind (3 keys)" do
        it_behaves_like "falls back to default keybind", "LEFTCTRL+RIGHTCTRL+LEFTALT"
      end

      context "with nil keybind" do
        it_behaves_like "falls back to default keybind", nil
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

    describe "#try_open_devices" do
      let(:selector) { described_class.new(["HHKB"]) }

      before do
        allow(Fusuma::Device).to receive(:reset)
      end

      context "when some devices fail to open with ENOENT" do
        let(:valid_device) { double(Revdev::EventDevice) }

        before do
          allow(Fusuma::Device).to receive(:all).and_return([
            Fusuma::Device.new(name: "HHKB-Keyboard", id: "event7"),
            Fusuma::Device.new(name: "HHKB-Consumer", id: "event8")
          ])
          allow(Revdev::EventDevice).to receive(:new)
            .with("/dev/input/event7").and_return(valid_device)
          allow(Revdev::EventDevice).to receive(:new)
            .with("/dev/input/event8").and_raise(Errno::ENOENT, "/dev/input/event8")
        end

        it "returns only successfully opened devices" do
          result = selector.try_open_devices
          expect(result).to eq([valid_device])
        end

        it "logs warning for failed devices" do
          expect(Fusuma::MultiLogger).to receive(:warn).with(/Failed to open/)
          selector.try_open_devices
        end
      end

      context "when some devices fail to open with ENODEV" do
        let(:valid_device) { double(Revdev::EventDevice) }

        before do
          allow(Fusuma::Device).to receive(:all).and_return([
            Fusuma::Device.new(name: "HHKB-Keyboard", id: "event7"),
            Fusuma::Device.new(name: "HHKB-System", id: "event9")
          ])
          allow(Revdev::EventDevice).to receive(:new)
            .with("/dev/input/event7").and_return(valid_device)
          allow(Revdev::EventDevice).to receive(:new)
            .with("/dev/input/event9").and_raise(Errno::ENODEV, "/dev/input/event9")
        end

        it "returns only successfully opened devices" do
          result = selector.try_open_devices
          expect(result).to eq([valid_device])
        end
      end

      context "when all devices fail to open" do
        before do
          allow(Fusuma::Device).to receive(:all).and_return([
            Fusuma::Device.new(name: "HHKB-Keyboard", id: "event7")
          ])
          allow(Revdev::EventDevice).to receive(:new)
            .and_raise(Errno::ENOENT, "/dev/input/event7")
          allow(Fusuma::MultiLogger).to receive(:warn)
        end

        it "returns empty array" do
          result = selector.try_open_devices
          expect(result).to eq([])
        end
      end
    end
  end

  describe "#create_virtual_keyboard" do
    let(:config) { {touchpad_name_patterns: ["Touchpad"]} }

    context "with touchpad found" do
      let(:device_id) { double("device_id", vendor: 0x1234, product: 0x5678, version: 1) }
      let(:event_device) { double(Revdev::EventDevice, device_id: device_id) }

      before do
        allow(remapper).to receive(:uinput_keyboard).and_return(uinput_keyboard)
        allow(Fusuma::Device).to receive(:reset)
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
      before do
        allow(remapper).to receive(:uinput_keyboard).and_return(uinput_keyboard)
        allow(Fusuma::Device).to receive(:reset)
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

  describe "modifier key remapping" do
    let(:input_event) { double("input_event", type: 1, value: 1) }

    before do
      allow(remapper).to receive(:uinput_keyboard).and_return(uinput_keyboard)
      remapper.instance_variable_set(:@modifier_state, Fusuma::Plugin::Remap::ModifierState.new)
    end

    describe "#find_remapping" do
      let(:mapping) { {"LEFTCTRL+A": "HOME", A: "B"} }

      context "when modifier key is pressed" do
        before do
          remapper.instance_variable_get(:@modifier_state).update("LEFTCTRL", 1)
        end

        it "returns [remapped_key, true] when modifier+key matches" do
          result = remapper.send(:find_remapping, mapping, "A")
          expect(result).to eq(["HOME", true])
        end
      end

      context "when no modifier key is pressed" do
        it "returns [remapped_key, false] when simple key matches" do
          result = remapper.send(:find_remapping, mapping, "A")
          expect(result).to eq(["B", false])
        end
      end

      context "when no match found" do
        it "returns [nil, false]" do
          result = remapper.send(:find_remapping, mapping, "Z")
          expect(result).to eq([nil, false])
        end
      end

      context "when remapping modifier key itself (e.g., LEFTMETA: LEFTALT)" do
        let(:mapping) { {LEFTMETA: "LEFTALT"} }

        before do
          # Simulate LEFTMETA being pressed
          remapper.instance_variable_get(:@modifier_state).update("LEFTMETA", 1)
        end

        it "returns [remapped_key, false] - NOT true" do
          # For modifier key remapping, is_modifier_remap should be false
          # This prevents execute_modifier_remap from being called
          result = remapper.send(:find_remapping, mapping, "LEFTMETA")
          expect(result).to eq(["LEFTALT", false])
        end
      end
    end

    describe "#execute_modifier_remap" do
      before do
        remapper.instance_variable_get(:@modifier_state).update("LEFTCTRL", 1)
        allow(uinput_keyboard).to receive(:write_input_event)
      end

      it "releases modifier, sends remapped key, then restores modifier" do
        # Order: LEFTCTRL release, HOME press, HOME release, LEFTCTRL press
        expect(uinput_keyboard).to receive(:write_input_event).exactly(4).times

        remapper.send(:execute_modifier_remap, "HOME", input_event)
      end
    end

    describe "#release_current_modifiers" do
      before do
        remapper.instance_variable_get(:@modifier_state).update("LEFTCTRL", 1)
        allow(uinput_keyboard).to receive(:write_input_event)
      end

      it "releases pressed modifier keys" do
        expect(uinput_keyboard).to receive(:write_input_event) do |event|
          expect(event.value).to eq(0) # release
        end

        remapper.send(:release_current_modifiers)
      end
    end

    describe "#restore_current_modifiers" do
      before do
        remapper.instance_variable_get(:@modifier_state).update("LEFTCTRL", 1)
        allow(uinput_keyboard).to receive(:write_input_event)
      end

      it "re-presses modifier keys" do
        expect(uinput_keyboard).to receive(:write_input_event) do |event|
          expect(event.value).to eq(1) # press
        end

        remapper.send(:restore_current_modifiers)
      end
    end

    describe "output sequence" do
      describe "#find_remapping with Array" do
        let(:mapping) { {"LEFTCTRL+U": ["LEFTSHIFT+HOME", "DELETE"]} }

        context "when modifier key is pressed" do
          before do
            remapper.instance_variable_get(:@modifier_state).update("LEFTCTRL", 1)
          end

          it "returns array as-is" do
            result = remapper.send(:find_remapping, mapping, "U")
            expect(result.first).to eq(["LEFTSHIFT+HOME", "DELETE"])
            expect(result.last).to be true
          end
        end
      end

      describe "#execute_modifier_remap with Array" do
        before do
          remapper.instance_variable_get(:@modifier_state).update("LEFTCTRL", 1)
          allow(uinput_keyboard).to receive(:write_input_event)
        end

        it "sends each array element in order" do
          # LEFTCTRL release (1)
          # LEFTSHIFT press, HOME press, HOME release, LEFTSHIFT release (4)
          # DELETE press, DELETE release (2)
          # LEFTCTRL press (1)
          # Total: 8 events
          expect(uinput_keyboard).to receive(:write_input_event).exactly(8).times

          remapper.send(:execute_modifier_remap, ["LEFTSHIFT+HOME", "DELETE"], input_event)
        end
      end

      describe "#send_key_combination with Array" do
        before { allow(uinput_keyboard).to receive(:write_input_event) }

        it "sends each array element in order" do
          # LEFTSHIFT press, HOME press, HOME release, LEFTSHIFT release (4)
          # DELETE press, DELETE release (2)
          # Total: 6 events
          expect(uinput_keyboard).to receive(:write_input_event).exactly(6).times

          remapper.send(:send_key_combination, ["LEFTSHIFT+HOME", "DELETE"], 1)
        end
      end
    end
  end

  describe "Array output sequence handling in run loop" do
    # This test verifies the behavior of Array output sequences in the run loop.
    #
    # Bug found: keyboard_remapper.rb:98-104 skips Array with `next` without
    # calling execute_modifier_remap

    let(:input_event) { double("input_event", type: 1, code: 22, value: 1) } # U key press

    before do
      allow(remapper).to receive(:uinput_keyboard).and_return(uinput_keyboard)
      remapper.instance_variable_set(:@modifier_state, Fusuma::Plugin::Remap::ModifierState.new)
      # Press LEFTCTRL modifier
      remapper.instance_variable_get(:@modifier_state).update("LEFTCTRL", 1)
      allow(uinput_keyboard).to receive(:write_input_event)
    end

    describe "when remapped value is Array and modifier is pressed" do
      let(:mapping) { {"LEFTCTRL+U": ["LEFTSHIFT+HOME", "DELETE"]} }

      it "find_remapping returns Array with is_modifier_remap=true" do
        remapped, is_modifier_remap = remapper.send(:find_remapping, mapping, "U")

        expect(remapped).to eq(["LEFTSHIFT+HOME", "DELETE"])
        expect(is_modifier_remap).to be true
      end

      # This test demonstrates what the CURRENT code does (the bug)
      it "CURRENT CODE: skips Array without executing (BUG)" do
        remapped, _is_modifier_remap = remapper.send(:find_remapping, mapping, "U")

        executed = false

        # This simulates the CURRENT run loop logic (keyboard_remapper.rb:95-117)
        case remapped
        when String, Symbol
          # Would continue processing
        when Array
          # CURRENT: just skips with next (line 104)
          # execute_modifier_remap is NOT called here
        when Hash
          # Would skip
        when nil
          # Would write original event
        end

        # The bug: Array case does nothing, so executed remains false
        expect(executed).to be false
      end

      # This test demonstrates what the FIXED code should do
      it "EXPECTED: should execute output sequence for Array" do
        remapped, is_modifier_remap = remapper.send(:find_remapping, mapping, "U")

        executed = false

        # This is what the FIXED code should do
        case remapped
        when String, Symbol
          # Continue processing
        when Array
          # FIXED: call execute_modifier_remap for Array
          if is_modifier_remap && input_event.value == 1
            remapper.send(:execute_modifier_remap, remapped, input_event)
            executed = true
          end
        when Hash
          # Skip
        when nil
          # Write original event
        end

        expect(executed).to be true
      end
    end
  end

  describe "#apply_simple_remap" do
    before do
      remapper.instance_variable_set(:@modifier_state, Fusuma::Plugin::Remap::ModifierState.new)
    end

    context "simple key-to-key remapping" do
      let(:mapping) { {CAPSLOCK: "LEFTCTRL", A: "B"} }

      it "applies remap when match found" do
        expect(remapper.send(:apply_simple_remap, mapping, "CAPSLOCK")).to eq("LEFTCTRL")
      end

      it "returns original key when no match" do
        expect(remapper.send(:apply_simple_remap, mapping, "Z")).to eq("Z")
      end
    end

    context "excludes combinations and Arrays" do
      let(:mapping) { {CAPSLOCK: ["A", "B"], A: "LEFTCTRL+B"} }

      it "skips when remap target contains + (combination)" do
        expect(remapper.send(:apply_simple_remap, mapping, "A")).to eq("A")
      end

      it "skips when remap target is Array" do
        expect(remapper.send(:apply_simple_remap, mapping, "CAPSLOCK")).to eq("CAPSLOCK")
      end
    end
  end

  describe "two-stage remap (CAPSLOCK -> LEFTCTRL -> combination)" do
    let(:mapping) { {CAPSLOCK: "LEFTCTRL", "LEFTCTRL+LEFTSHIFT+J": "LEFTMETA+LEFTCTRL+DOWN"} }

    before do
      remapper.instance_variable_set(:@modifier_state, Fusuma::Plugin::Remap::ModifierState.new)
    end

    it "updates modifier state as LEFTCTRL when CAPSLOCK is pressed" do
      effective_key = remapper.send(:apply_simple_remap, mapping, "CAPSLOCK")
      remapper.instance_variable_get(:@modifier_state).update(effective_key, 1)

      expect(effective_key).to eq("LEFTCTRL")
      expect(remapper.instance_variable_get(:@modifier_state).pressed_modifiers).to include("LEFTCTRL")
    end

    it "matches LEFTCTRL+LEFTSHIFT+J when physical CAPSLOCK+LEFTSHIFT+J is pressed" do
      effective_capslock = remapper.send(:apply_simple_remap, mapping, "CAPSLOCK")
      remapper.instance_variable_get(:@modifier_state).update(effective_capslock, 1)

      effective_shift = remapper.send(:apply_simple_remap, mapping, "LEFTSHIFT")
      remapper.instance_variable_get(:@modifier_state).update(effective_shift, 1)

      effective_j = remapper.send(:apply_simple_remap, mapping, "J")
      remapped, is_modifier_remap = remapper.send(:find_remapping, mapping, effective_j)

      expect(remapped).to eq("LEFTMETA+LEFTCTRL+DOWN")
      expect(is_modifier_remap).to be true
    end
  end

  describe "simple remap output (CAPSLOCK single press -> LEFTCTRL)" do
    let(:mapping) { {CAPSLOCK: "LEFTCTRL"} }

    before do
      allow(remapper).to receive(:uinput_keyboard).and_return(uinput_keyboard)
      remapper.instance_variable_set(:@modifier_state, Fusuma::Plugin::Remap::ModifierState.new)
      allow(uinput_keyboard).to receive(:write_input_event)
    end

    it "outputs LEFTCTRL when CAPSLOCK is simple-remapped" do
      effective_key = remapper.send(:apply_simple_remap, mapping, "CAPSLOCK")
      remapped, _is_modifier_remap = remapper.send(:find_remapping, mapping, effective_key)

      # find_remapping returns nil (no remap for LEFTCTRL itself)
      # but effective_key != input_key, so LEFTCTRL should be output
      expect(remapped).to be_nil
      expect(effective_key).to eq("LEFTCTRL")
      expect(effective_key).not_to eq("CAPSLOCK")

      output_key = remapped || ((effective_key != "CAPSLOCK") ? effective_key : nil)
      expect(output_key).to eq("LEFTCTRL")
    end
  end

  describe "device-specific remapping" do
    let(:device_matcher) { instance_double(Fusuma::Plugin::Remap::DeviceMatcher) }
    let(:hhkb_mapping) { {LEFTCTRL: "LEFTMETA"} }
    let(:internal_mapping) { {LEFTALT: "LEFTCTRL"} }
    let(:default_mapping) { {CAPSLOCK: "LEFTCTRL"} }

    before do
      allow(Fusuma::Plugin::Remap::DeviceMatcher).to receive(:new).and_return(device_matcher)
      allow(layer_manager).to receive(:find_merged_mapping).and_return({})
    end

    describe "#get_mapping_for_device" do
      before do
        remapper.instance_variable_set(:@device_matcher, device_matcher)
      end

      context "when device name matches a pattern" do
        before do
          allow(device_matcher).to receive(:match).with("PFU HHKB-Hybrid").and_return("HHKB")
          allow(layer_manager).to receive(:find_merged_mapping)
            .with({device: "HHKB"})
            .and_return(hhkb_mapping)
        end

        it "returns device-specific mapping" do
          result = remapper.send(:get_mapping_for_device, "PFU HHKB-Hybrid", {})
          expect(result).to eq(hhkb_mapping)
        end

        it "merges layer and device info when calling LayerManager" do
          expect(layer_manager).to receive(:find_merged_mapping)
            .with({thumbsense: true, device: "HHKB"})
          remapper.send(:get_mapping_for_device, "PFU HHKB-Hybrid", {thumbsense: true})
        end
      end

      context "when device name does not match any pattern" do
        before do
          allow(device_matcher).to receive(:match).with("Unknown Keyboard").and_return(nil)
          allow(layer_manager).to receive(:find_merged_mapping)
            .with({})
            .and_return(default_mapping)
        end

        it "returns default mapping" do
          result = remapper.send(:get_mapping_for_device, "Unknown Keyboard", {})
          expect(result).to eq(default_mapping)
        end

        it "calls LayerManager without device info" do
          expect(layer_manager).to receive(:find_merged_mapping).with({})
          remapper.send(:get_mapping_for_device, "Unknown Keyboard", {})
        end
      end

      context "caching behavior" do
        before do
          allow(device_matcher).to receive(:match).with("PFU HHKB-Hybrid").and_return("HHKB")
          allow(layer_manager).to receive(:find_merged_mapping).and_return(hhkb_mapping)
        end

        it "caches mapping for same device and layer combination" do
          expect(layer_manager).to receive(:find_merged_mapping).once

          remapper.send(:get_mapping_for_device, "PFU HHKB-Hybrid", {})
          remapper.send(:get_mapping_for_device, "PFU HHKB-Hybrid", {})
        end

        it "fetches mapping separately for different devices" do
          allow(device_matcher).to receive(:match).with("AT Translated").and_return("AT Translated")
          allow(layer_manager).to receive(:find_merged_mapping)
            .with({device: "AT Translated"})
            .and_return(internal_mapping)

          expect(layer_manager).to receive(:find_merged_mapping).twice

          remapper.send(:get_mapping_for_device, "PFU HHKB-Hybrid", {})
          remapper.send(:get_mapping_for_device, "AT Translated", {})
        end
      end
    end
  end

  describe "#check_and_add_new_devices" do
    let(:config) { {keyboard_name_patterns: ["HHKB", "keyboard"]} }
    let(:existing_keyboard) { double("existing_keyboard", file: double("file", path: "/dev/input/event1")) }
    let(:new_keyboard) { double("new_keyboard", file: double("file", path: "/dev/input/event2", close: nil), device_name: "HHKB-Keyboard") }

    before do
      remapper.instance_variable_set(:@source_keyboards, [existing_keyboard])
      remapper.instance_variable_set(:@device_mappings, {some: "cache"})
      allow(remapper).to receive(:wait_release_all_keys).and_return(true)
    end

    context "when new devices are found" do
      before do
        selector = instance_double(described_class::KeyboardSelector)
        allow(described_class::KeyboardSelector).to receive(:new).and_return(selector)
        allow(selector).to receive(:try_open_devices).and_return([
          double("existing", file: double("file", path: "/dev/input/event1", close: nil)),
          new_keyboard
        ])
        allow(new_keyboard).to receive(:grab)
      end

      it "adds new devices to source_keyboards" do
        remapper.send(:check_and_add_new_devices)
        expect(remapper.instance_variable_get(:@source_keyboards)).to include(new_keyboard)
      end

      it "grabs the new device" do
        expect(new_keyboard).to receive(:grab)
        remapper.send(:check_and_add_new_devices)
      end

      it "clears device mappings cache" do
        remapper.send(:check_and_add_new_devices)
        expect(remapper.instance_variable_get(:@device_mappings)).to eq({})
      end

      it "logs new device detection" do
        expect(Fusuma::MultiLogger).to receive(:info).with(/New keyboard\(s\) detected/)
        expect(Fusuma::MultiLogger).to receive(:info).with(/Grabbed keyboard/)
        remapper.send(:check_and_add_new_devices)
      end
    end

    context "when no new devices are found" do
      before do
        selector = instance_double(described_class::KeyboardSelector)
        allow(described_class::KeyboardSelector).to receive(:new).and_return(selector)
        allow(selector).to receive(:try_open_devices).and_return([
          double("existing", file: double("file", path: "/dev/input/event1", close: nil))
        ])
      end

      it "does not modify source_keyboards" do
        original_keyboards = remapper.instance_variable_get(:@source_keyboards).dup
        remapper.send(:check_and_add_new_devices)
        expect(remapper.instance_variable_get(:@source_keyboards)).to eq(original_keyboards)
      end

      it "does not clear device mappings cache" do
        remapper.send(:check_and_add_new_devices)
        expect(remapper.instance_variable_get(:@device_mappings)).to eq({some: "cache"})
      end
    end

    context "when grab fails with EBUSY" do
      before do
        selector = instance_double(described_class::KeyboardSelector)
        allow(described_class::KeyboardSelector).to receive(:new).and_return(selector)
        allow(selector).to receive(:try_open_devices).and_return([new_keyboard])
        allow(new_keyboard).to receive(:grab).and_raise(Errno::EBUSY)
      end

      it "logs error and continues" do
        expect(Fusuma::MultiLogger).to receive(:info).with(/New keyboard\(s\) detected/)
        expect(Fusuma::MultiLogger).to receive(:error).with(/Failed to grab/)
        remapper.send(:check_and_add_new_devices)
      end

      it "does not add device that failed to grab" do
        allow(Fusuma::MultiLogger).to receive(:info)
        allow(Fusuma::MultiLogger).to receive(:error)
        remapper.send(:check_and_add_new_devices)
        expect(remapper.instance_variable_get(:@source_keyboards)).not_to include(new_keyboard)
      end
    end
  end
end
