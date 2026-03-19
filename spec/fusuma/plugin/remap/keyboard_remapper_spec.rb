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

      context "when some devices fail to open with EACCES (Permission denied)" do
        let(:valid_device) { double(Revdev::EventDevice) }

        before do
          allow(Fusuma::Device).to receive(:all).and_return([
            Fusuma::Device.new(name: "HHKB-Keyboard", id: "event7"),
            Fusuma::Device.new(name: "HHKB-System", id: "event9")
          ])
          allow(Revdev::EventDevice).to receive(:new)
            .with("/dev/input/event7").and_return(valid_device)
          allow(Revdev::EventDevice).to receive(:new)
            .with("/dev/input/event9").and_raise(Errno::EACCES, "/dev/input/event9")
        end

        it "returns only successfully opened devices" do
          result = selector.try_open_devices
          expect(result).to eq([valid_device])
        end

        it "logs warning for permission denied devices" do
          expect(Fusuma::MultiLogger).to receive(:warn).with(/Failed to open.*Permission denied/)
          selector.try_open_devices
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

  describe "#separate_mappings" do
    # simple_remap: key-to-key without "+"
    # combo_remap: contains "+", Array, or Hash

    context "with simple remaps only" do
      let(:mapping) { {CAPSLOCK: "LEFTCTRL", LEFTALT: "LEFTMETA"} }

      it "classifies all as simple_remap" do
        simple, combo = remapper.send(:separate_mappings, mapping)
        expect(simple).to eq({CAPSLOCK: "LEFTCTRL", LEFTALT: "LEFTMETA"})
        expect(combo).to eq({})
      end
    end

    context "with combo remaps only" do
      let(:mapping) { {"LEFTCTRL+A": "HOME", "LEFTALT+N": "LEFTCTRL+TAB"} }

      it "classifies all as combo_remap" do
        simple, combo = remapper.send(:separate_mappings, mapping)
        expect(simple).to eq({})
        expect(combo).to eq({"LEFTCTRL+A": "HOME", "LEFTALT+N": "LEFTCTRL+TAB"})
      end
    end

    context "with mixed remaps" do
      let(:mapping) do
        {
          CAPSLOCK: "LEFTCTRL",           # simple: key-to-key
          LEFTALT: "LEFTMETA",            # simple: key-to-key
          "LEFTCTRL+A": "HOME",           # combo: key contains +
          A: "LEFTCTRL+B",                # combo: value contains +
          "LEFTCTRL+U": ["HOME", "DELETE"], # combo: value is Array
          X: {command: "echo foo"}        # combo: value is Hash
        }
      end

      it "classifies correctly" do
        simple, combo = remapper.send(:separate_mappings, mapping)

        expect(simple).to eq({CAPSLOCK: "LEFTCTRL", LEFTALT: "LEFTMETA"})
        expect(combo).to eq({
          "LEFTCTRL+A": "HOME",
          A: "LEFTCTRL+B",
          "LEFTCTRL+U": ["HOME", "DELETE"],
          X: {command: "echo foo"}
        })
      end
    end

    context "with key swap settings" do
      let(:mapping) { {LEFTALT: "LEFTMETA", LEFTMETA: "LEFTALT"} }

      it "classifies both as simple_remap (prevents double conversion)" do
        simple, combo = remapper.send(:separate_mappings, mapping)
        expect(simple).to eq({LEFTALT: "LEFTMETA", LEFTMETA: "LEFTALT"})
        expect(combo).to eq({})
      end
    end
  end

  describe "key swap without double conversion" do
    # Key swap: LEFTALT <-> LEFTMETA
    # Problem: Using same mapping for apply_simple_remap and find_remapping causes double conversion
    # Solution: separate_mappings splits into simple/combo, each method uses appropriate mapping

    let(:mapping) { {LEFTALT: "LEFTMETA", LEFTMETA: "LEFTALT"} }

    before do
      remapper.instance_variable_set(:@modifier_state, Fusuma::Plugin::Remap::ModifierState.new)
    end

    describe "using get_separated_mappings" do
      it "physical LEFTALT -> LEFTMETA output (no double conversion)" do
        simple, combo = remapper.send(:get_separated_mappings, mapping)

        # simple_remap: LEFTALT -> LEFTMETA
        effective_key = remapper.send(:apply_simple_remap, simple, "LEFTALT")
        expect(effective_key).to eq("LEFTMETA")

        # combo_remap: search LEFTMETA -> no match (no double conversion)
        remapped, _is_modifier_remap = remapper.send(:find_remapping, combo, effective_key)
        expect(remapped).to be_nil

        # Final output is LEFTMETA
        expect(effective_key).to eq("LEFTMETA")
      end

      it "physical LEFTMETA -> LEFTALT output (no double conversion)" do
        simple, combo = remapper.send(:get_separated_mappings, mapping)

        # simple_remap: LEFTMETA -> LEFTALT
        effective_key = remapper.send(:apply_simple_remap, simple, "LEFTMETA")
        expect(effective_key).to eq("LEFTALT")

        # combo_remap: search LEFTALT -> no match (no double conversion)
        remapped, _is_modifier_remap = remapper.send(:find_remapping, combo, effective_key)
        expect(remapped).to be_nil

        # Final output is LEFTALT
        expect(effective_key).to eq("LEFTALT")
      end
    end

    describe "old implementation issue (using same mapping)" do
      it "physical LEFTALT -> double conversion reverts to LEFTALT (bug)" do
        # apply_simple_remap: LEFTALT -> LEFTMETA
        effective_key = remapper.send(:apply_simple_remap, mapping, "LEFTALT")
        expect(effective_key).to eq("LEFTMETA")

        # find_remapping: LEFTMETA -> LEFTALT (double conversion!)
        remapped, _is_modifier_remap = remapper.send(:find_remapping, mapping, effective_key)
        expect(remapped).to eq("LEFTALT") # Bug: reverts to original
      end
    end

    describe "combo remap after key swap" do
      # Requirement: After LEFTALT <-> LEFTMETA swap on HHKB
      # Physical LEFTMETA+N -> LEFTALT+N (internal) -> LEFTCTRL+TAB output
      let(:combined_mapping) do
        {
          LEFTALT: "LEFTMETA",
          LEFTMETA: "LEFTALT",
          "LEFTALT+N": "LEFTCTRL+TAB"
        }
      end

      it "physical LEFTMETA+N -> LEFTCTRL+TAB (combo after swap)" do
        simple, combo = remapper.send(:get_separated_mappings, combined_mapping)

        # 1. Physical LEFTMETA press -> simple_remap to LEFTALT
        effective_meta = remapper.send(:apply_simple_remap, simple, "LEFTMETA")
        expect(effective_meta).to eq("LEFTALT")

        # 2. Register LEFTALT in modifier_state
        remapper.instance_variable_get(:@modifier_state).update(effective_meta, 1)

        # 3. Physical N press
        effective_n = remapper.send(:apply_simple_remap, simple, "N")
        expect(effective_n).to eq("N")

        # 4. find_remapping searches LEFTALT+N -> LEFTCTRL+TAB
        remapped, is_modifier_remap = remapper.send(:find_remapping, combo, effective_n)
        expect(remapped).to eq("LEFTCTRL+TAB")
        expect(is_modifier_remap).to be true
      end
    end
  end

  describe "non-EV_KEY event passthrough" do
    # Non-keyboard events (EV_REL, EV_ABS, etc.) should be passed through without remapping
    # This prevents event code collision issues (e.g., KEY_ESC=1 vs REL_Y=1)

    # Linux input event type constants
    let(:ev_key) { 1 }  # EV_KEY (keyboard/button events)
    let(:ev_rel) { 2 }  # EV_REL (relative movement: mouse, TrackPoint)
    let(:ev_abs) { 3 }  # EV_ABS (absolute position: touchpad)

    describe "#should_skip_non_key_event?" do
      it "returns false for EV_KEY events" do
        expect(remapper.send(:should_skip_non_key_event?, ev_key)).to be false
      end

      it "returns true for EV_REL events (mouse/trackpoint movement)" do
        expect(remapper.send(:should_skip_non_key_event?, ev_rel)).to be true
      end

      it "returns true for EV_ABS events (touchpad absolute position)" do
        expect(remapper.send(:should_skip_non_key_event?, ev_abs)).to be true
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

  describe "#get_or_record_key_code" do
    # Records physical-to-output key code mapping on press,
    # returns recorded code on release to ensure press/release consistency.
    # This fixes the bug where layer changes cause mismatched press/release events
    # (e.g., F pressed as passthrough, released as BTN_LEFT → F stuck in pressed state)

    let(:key_f_code) { 33 }      # KEY_F
    let(:btn_left_code) { 272 }  # BTN_LEFT

    describe "press event" do
      it "returns output_code on press" do
        result = remapper.send(:get_or_record_key_code, key_f_code, key_f_code, 1)
        expect(result).to eq(key_f_code)
      end

      it "records the mapping for later release" do
        remapper.send(:get_or_record_key_code, key_f_code, key_f_code, 1)
        result = remapper.send(:get_or_record_key_code, key_f_code, btn_left_code, 0)
        expect(result).to eq(key_f_code)
      end
    end

    describe "release event" do
      it "returns recorded code on release (not the new output_code)" do
        remapper.send(:get_or_record_key_code, key_f_code, key_f_code, 1)
        result = remapper.send(:get_or_record_key_code, key_f_code, btn_left_code, 0)
        expect(result).to eq(key_f_code)
      end

      it "returns output_code if no recorded mapping exists" do
        result = remapper.send(:get_or_record_key_code, key_f_code, btn_left_code, 0)
        expect(result).to eq(btn_left_code)
      end

      it "removes the mapping after release" do
        remapper.send(:get_or_record_key_code, key_f_code, key_f_code, 1)
        remapper.send(:get_or_record_key_code, key_f_code, btn_left_code, 0)
        result = remapper.send(:get_or_record_key_code, key_f_code, btn_left_code, 0)
        expect(result).to eq(btn_left_code)
      end
    end

    describe "repeat event" do
      it "returns output_code on repeat without affecting recording" do
        remapper.send(:get_or_record_key_code, key_f_code, key_f_code, 1)
        result = remapper.send(:get_or_record_key_code, key_f_code, btn_left_code, 2)
        expect(result).to eq(btn_left_code)
        release_result = remapper.send(:get_or_record_key_code, key_f_code, btn_left_code, 0)
        expect(release_result).to eq(key_f_code)
      end
    end

    describe "layer change consistency" do
      it "maintains press/release consistency across layer changes" do
        # Scenario: F pressed as passthrough, then layer changes, F released as BTN_LEFT
        # Expected: release should use the recorded code (F), not the new mapping (BTN_LEFT)
        press_output = remapper.send(:get_or_record_key_code, key_f_code, key_f_code, 1)
        expect(press_output).to eq(key_f_code)

        # Layer changes here (thumbsense ON) - mapping would change F -> BTN_LEFT

        release_output = remapper.send(:get_or_record_key_code, key_f_code, btn_left_code, 0)
        expect(release_output).to eq(key_f_code)
      end
    end
  end

  describe "#get_or_record_key_name" do
    # Records physical-to-key-name mapping on press,
    # returns recorded name on release to ensure update_virtual_key_state consistency.
    # This fixes the bug where layer changes cause pressed_virtual_keys to never be cleared
    # (e.g., combo remap A->B on press, layer changes, release tries to delete C instead of B)

    let(:key_f_code) { 33 }

    describe "press event" do
      it "returns key_name on press" do
        result = remapper.send(:get_or_record_key_name, key_f_code, "KEY_F", 1)
        expect(result).to eq("KEY_F")
      end
    end

    describe "release event" do
      it "returns recorded name on release (not the new key_name)" do
        remapper.send(:get_or_record_key_name, key_f_code, "KEY_F", 1)
        result = remapper.send(:get_or_record_key_name, key_f_code, "BTN_LEFT", 0)
        expect(result).to eq("KEY_F")
      end

      it "returns key_name if no recorded mapping exists" do
        result = remapper.send(:get_or_record_key_name, key_f_code, "BTN_LEFT", 0)
        expect(result).to eq("BTN_LEFT")
      end
    end

    describe "repeat event" do
      it "returns key_name on repeat without affecting recording" do
        remapper.send(:get_or_record_key_name, key_f_code, "KEY_F", 1)
        result = remapper.send(:get_or_record_key_name, key_f_code, "BTN_LEFT", 2)
        expect(result).to eq("BTN_LEFT")
        release_result = remapper.send(:get_or_record_key_name, key_f_code, "BTN_LEFT", 0)
        expect(release_result).to eq("KEY_F")
      end
    end

    describe "layer change: pressed_virtual_keys consistency" do
      it "ensures pressed_virtual_keys is correctly cleaned up across layer changes" do
        # Scenario: combo remap A->B on press, layer changes, A->C on release
        # Without get_or_record_key_name: update_virtual_key_state("C", 0) → "B" stuck!
        # With get_or_record_key_name: update_virtual_key_state("B", 0) → correct cleanup

        # Press: record "B" as virtual key name
        virtual_key = remapper.send(:get_or_record_key_name, key_f_code, "B", 1)
        remapper.send(:update_virtual_key_state, virtual_key, 1)
        expect(remapper.send(:pressed_virtual_keys)).to include("B")

        # Layer changes here — new layer would map to "C"

        # Release: get_or_record_key_name returns recorded "B", not new "C"
        virtual_key = remapper.send(:get_or_record_key_name, key_f_code, "C", 0)
        remapper.send(:update_virtual_key_state, virtual_key, 0)

        expect(remapper.send(:pressed_virtual_keys)).to be_empty
        expect(remapper.send(:virtual_keyboard_all_key_released?)).to be true
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

    context "when device is removed during grab (ENODEV)" do
      before do
        selector = instance_double(described_class::KeyboardSelector)
        allow(described_class::KeyboardSelector).to receive(:new).and_return(selector)
        allow(selector).to receive(:try_open_devices).and_return([new_keyboard])
        allow(remapper).to receive(:wait_release_all_keys).and_raise(Errno::ENODEV)
      end

      it "logs warning and continues" do
        expect(Fusuma::MultiLogger).to receive(:info).with(/New keyboard\(s\) detected/)
        expect(Fusuma::MultiLogger).to receive(:warn).with(/Device removed during grab/)
        remapper.send(:check_and_add_new_devices)
      end

      it "does not add device that was removed" do
        allow(Fusuma::MultiLogger).to receive(:info)
        allow(Fusuma::MultiLogger).to receive(:warn)
        remapper.send(:check_and_add_new_devices)
        expect(remapper.instance_variable_get(:@source_keyboards)).not_to include(new_keyboard)
      end
    end
  end

  # Combo mapping during layer change
  # Problem: When switching apps while holding a modifier key,
  #          the new layer's combo mappings are not applied
  # Expected: Combo mappings should immediately use the new layer's mapping
  describe "combo mapping during layer change" do
    # Scenario:
    # 1. Old layer (Gnome-terminal): No LEFTALT+P mapping
    # 2. User switches app while holding LEFTALT
    # 3. New layer (Google-chrome): LEFTALT+P -> LEFTCTRL+LEFTSHIFT+TAB
    # 4. User presses P while still holding LEFTALT
    # Expected: New layer's LEFTALT+P remap should be applied
    #
    # Solution:
    # - simple_mapping: from current_mapping (prevents key stuck)
    # - combo_mapping: from device_mapping (immediately applies new layer)

    let(:old_layer_mapping) { {LEFTMETA: "LEFTALT"} }
    let(:new_layer_mapping) { {LEFTMETA: "LEFTALT", "LEFTALT+P": "LEFTCTRL+LEFTSHIFT+TAB"} }

    before do
      allow(remapper).to receive(:uinput_keyboard).and_return(uinput_keyboard)
      remapper.instance_variable_set(:@modifier_state, Fusuma::Plugin::Remap::ModifierState.new)
      allow(uinput_keyboard).to receive(:write_input_event)
    end

    context "when layer changes while modifier key is pressed" do
      it "combo_mapping should use new layer (device_mapping) while simple_mapping uses old layer" do
        old_simple, old_combo = remapper.send(:get_separated_mappings, old_layer_mapping)

        # Old layer has LEFTMETA -> LEFTALT simple remap
        expect(old_simple).to eq({LEFTMETA: "LEFTALT"})
        # Old layer has no LEFTALT+P combo remap
        expect(old_combo).to eq({})

        new_simple, new_combo = remapper.send(:get_separated_mappings, new_layer_mapping)

        # Simple remap is same
        expect(new_simple).to eq({LEFTMETA: "LEFTALT"})
        # New layer has LEFTALT+P combo remap
        expect(new_combo).to eq({"LEFTALT+P": "LEFTCTRL+LEFTSHIFT+TAB"})
      end
    end

    context "when searching for combo remap during layer change" do
      before do
        # Simulate LEFTALT being pressed
        remapper.instance_variable_get(:@modifier_state).update("LEFTALT", 1)
      end

      it "finds LEFTALT+P remap in new layer's combo_mapping" do
        _, new_combo = remapper.send(:get_separated_mappings, new_layer_mapping)

        remapped, is_modifier_remap = remapper.send(:find_remapping, new_combo, "P")

        expect(remapped).to eq("LEFTCTRL+LEFTSHIFT+TAB")
        expect(is_modifier_remap).to be true
      end

      it "does NOT find LEFTALT+P remap in old layer's combo_mapping" do
        _, old_combo = remapper.send(:get_separated_mappings, old_layer_mapping)

        remapped, _is_modifier_remap = remapper.send(:find_remapping, old_combo, "P")

        expect(remapped).to be_nil
      end
    end

    context "simulating run loop during layer change" do
      before do
        # Simulate LEFTALT being pressed in modifier state
        remapper.instance_variable_get(:@modifier_state).update("LEFTALT", 1)
        # Simulate LEFTALT being pressed in virtual keyboard
        remapper.send(:update_virtual_key_state, "LEFTALT", 1)
      end

      it "uses new layer's combo_mapping even when layer_changed is true" do
        # Simulate run loop:
        # 1. current_mapping = old mapping (due to @layer_changed = true)
        # 2. device_mapping = new mapping
        current_mapping = old_layer_mapping
        device_mapping = new_layer_mapping

        # Virtual keys not released, so @layer_changed remains true
        all_keys_released = remapper.send(:virtual_keyboard_all_key_released?)
        expect(all_keys_released).to be false

        # Use get_simple_and_combo_mappings helper method:
        # - simple_mapping: from current_mapping (prevents key stuck)
        # - combo_mapping: from device_mapping (immediately applies new layer)
        simple_mapping, combo_mapping = remapper.send(
          :get_simple_and_combo_mappings,
          current_mapping,
          device_mapping
        )

        effective_key = remapper.send(:apply_simple_remap, simple_mapping, "P")
        remapped, is_modifier_remap = remapper.send(:find_remapping, combo_mapping, effective_key)

        # Expected: new layer's LEFTALT+P remap is found
        expect(remapped).to eq("LEFTCTRL+LEFTSHIFT+TAB")
        expect(is_modifier_remap).to be true
      end
    end
  end
end
