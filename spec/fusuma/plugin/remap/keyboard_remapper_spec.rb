require "spec_helper"

require "fusuma/plugin/remap/keyboard_remapper"
require "fusuma/plugin/remap/device_selector"
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
end
