require "spec_helper"

require "fusuma/plugin/remap/touchpad_remapper"
require "fusuma/device"

RSpec.describe Fusuma::Plugin::Remap::TouchpadRemapper do
  let(:fusuma_writer) { instance_double("IO", write: nil) }
  let(:absinfo) { {absmin: 0, absmax: 1000, absfuzz: 0, absflat: 0, absresolution: 0} }
  let(:source_touchpad) do
    instance_double(
      "Revdev::EventDevice",
      file: instance_double("File"),
      absinfo_for_axis: absinfo
    )
  end
  let(:source_touchpads) { [source_touchpad] }

  describe "#initialize" do
    context "without touchpad_name_patterns" do
      let(:remapper) do
        described_class.new(
          fusuma_writer: fusuma_writer,
          source_touchpads: source_touchpads
        )
      end

      it "initializes with nil touchpad_name_patterns" do
        expect(remapper.instance_variable_get(:@touchpad_name_patterns)).to be_nil
      end

      it "stores source_touchpads" do
        expect(remapper.instance_variable_get(:@source_touchpads)).to eq(source_touchpads)
      end

      it "stores fusuma_writer" do
        expect(remapper.instance_variable_get(:@fusuma_writer)).to eq(fusuma_writer)
      end
    end

    context "with touchpad_name_patterns" do
      let(:touchpad_name_patterns) { ["Touchpad", "SynPS/2"] }
      let(:remapper) do
        described_class.new(
          fusuma_writer: fusuma_writer,
          source_touchpads: source_touchpads,
          touchpad_name_patterns: touchpad_name_patterns
        )
      end

      it "stores touchpad_name_patterns in instance variable" do
        expect(remapper.instance_variable_get(:@touchpad_name_patterns)).to eq(touchpad_name_patterns)
      end
    end

    context "with string touchpad_name_patterns" do
      let(:touchpad_name_patterns) { "Touchpad" }
      let(:remapper) do
        described_class.new(
          fusuma_writer: fusuma_writer,
          source_touchpads: source_touchpads,
          touchpad_name_patterns: touchpad_name_patterns
        )
      end

      it "stores single pattern as string" do
        expect(remapper.instance_variable_get(:@touchpad_name_patterns)).to eq("Touchpad")
      end
    end

    it "initializes palm_detectors for each source_touchpad" do
      remapper = described_class.new(
        fusuma_writer: fusuma_writer,
        source_touchpads: source_touchpads
      )
      expect(remapper.instance_variable_get(:@palm_detectors).keys).to eq(source_touchpads)
    end
  end

  describe "#run" do
    let(:uinput) { instance_double("Fusuma::Plugin::Remap::UinputTouchpad", create_from_device: nil, destroy: nil) }
    let(:mock_file) { instance_double("File") }

    describe "Errno::ENODEV handling" do
      let(:run_source_touchpad) do
        device = instance_double(
          "Revdev::EventDevice",
          file: mock_file,
          absinfo_for_axis: absinfo
        )
        device
      end

      let(:remapper) do
        described_class.new(
          fusuma_writer: fusuma_writer,
          source_touchpads: [run_source_touchpad],
          touchpad_name_patterns: ["Touchpad"]
        )
      end

      before do
        allow(remapper).to receive(:uinput).and_return(uinput)
        allow(remapper).to receive(:create_virtual_touchpad)
      end

      it "catches Errno::ENODEV and calls reload_touchpads" do
        call_count = 0
        allow(IO).to receive(:select).and_return([[mock_file]])
        allow(run_source_touchpad).to receive(:read_input_event) do
          call_count += 1
          if call_count == 1
            raise Errno::ENODEV, "/dev/input/event3"
          else
            raise IOError, "closed stream"
          end
        end
        allow(remapper).to receive(:reload_touchpads)

        expect(Fusuma::MultiLogger).to receive(:error).with(/Touchpad device is removed/)
        expect(Fusuma::MultiLogger).to receive(:info).with(/Waiting for touchpad to reconnect/)
        expect(Fusuma::MultiLogger).to receive(:error).with(/Touchpad IO error/)
        expect(remapper).to receive(:reload_touchpads)

        remapper.run
      end
    end

    describe "IOError handling" do
      let(:run_source_touchpad) do
        device = instance_double(
          "Revdev::EventDevice",
          file: mock_file,
          absinfo_for_axis: absinfo
        )
        allow(device).to receive(:read_input_event).and_raise(IOError, "closed stream")
        device
      end

      let(:remapper) do
        described_class.new(
          fusuma_writer: fusuma_writer,
          source_touchpads: [run_source_touchpad],
          touchpad_name_patterns: ["Touchpad"]
        )
      end

      before do
        allow(remapper).to receive(:uinput).and_return(uinput)
        allow(remapper).to receive(:create_virtual_touchpad)
      end

      it "catches IOError and logs error" do
        allow(IO).to receive(:select).and_return([[mock_file]])

        expect(Fusuma::MultiLogger).to receive(:error).with(/Touchpad IO error/)

        remapper.run
      end
    end

    describe "ensure block" do
      let(:run_source_touchpad) do
        device = instance_double(
          "Revdev::EventDevice",
          file: mock_file,
          absinfo_for_axis: absinfo
        )
        allow(device).to receive(:read_input_event).and_raise(IOError, "test")
        device
      end

      let(:remapper) do
        described_class.new(
          fusuma_writer: fusuma_writer,
          source_touchpads: [run_source_touchpad],
          touchpad_name_patterns: ["Touchpad"]
        )
      end

      before do
        allow(remapper).to receive(:uinput).and_return(uinput)
        allow(remapper).to receive(:create_virtual_touchpad)
      end

      it "calls @destroy in ensure block" do
        allow(IO).to receive(:select).and_return([[mock_file]])
        allow(Fusuma::MultiLogger).to receive(:error)

        destroy_called = false
        remapper.instance_variable_set(:@destroy, -> { destroy_called = true })

        remapper.run

        expect(destroy_called).to be true
      end
    end
  end

  describe "#reload_touchpads" do
    let(:uinput) { instance_double("Fusuma::Plugin::Remap::UinputTouchpad", create_from_device: nil, destroy: nil) }
    let(:new_device) { Fusuma::Device.new(name: "New Touchpad", id: "event5") }
    let(:new_touchpad) { instance_double("Revdev::EventDevice", absinfo_for_axis: absinfo) }
    let(:remapper) do
      described_class.new(
        fusuma_writer: fusuma_writer,
        source_touchpads: source_touchpads,
        touchpad_name_patterns: ["Touchpad"]
      )
    end

    before do
      allow(remapper).to receive(:uinput).and_return(uinput)
      allow(Fusuma::Device).to receive(:reset)
      allow(Fusuma::Device).to receive(:all).and_return([new_device])
      allow(Revdev::EventDevice).to receive(:new).and_return(new_touchpad)
    end

    it "destroys existing uinput" do
      expect(uinput).to receive(:destroy)
      remapper.send(:reload_touchpads)
    end

    it "handles IOError when destroying uinput (already destroyed)" do
      allow(uinput).to receive(:destroy).and_raise(IOError)
      expect { remapper.send(:reload_touchpads) }.not_to raise_error
    end

    it "resets @uinput to nil" do
      remapper.instance_variable_set(:@uinput, uinput)
      remapper.send(:reload_touchpads)
      expect(remapper.instance_variable_get(:@uinput)).to be_nil
    end

    it "calls Fusuma::Device.reset to refresh device cache" do
      expect(Fusuma::Device).to receive(:reset)
      remapper.send(:reload_touchpads)
    end

    context "with touchpad_name_patterns set" do
      it "filters devices by touchpad_name_patterns" do
        expect(Fusuma::Device).to receive(:all).and_return([new_device])
        remapper.send(:reload_touchpads)
      end
    end

    context "without touchpad_name_patterns" do
      let(:remapper) do
        described_class.new(
          fusuma_writer: fusuma_writer,
          source_touchpads: source_touchpads,
          touchpad_name_patterns: nil
        )
      end

      it "uses Fusuma::Device.available" do
        expect(Fusuma::Device).to receive(:available).and_return([new_device])
        remapper.send(:reload_touchpads)
      end
    end

    context "when no devices found" do
      it "sleeps and retries until device is found" do
        call_count = 0
        allow(Fusuma::Device).to receive(:all) do
          call_count += 1
          if call_count < 3
            []
          else
            [new_device]
          end
        end
        allow(remapper).to receive(:sleep)

        expect(remapper).to receive(:sleep).with(3).exactly(2).times
        remapper.send(:reload_touchpads)
      end
    end

    it "reinitializes palm_detectors for new devices" do
      remapper.send(:reload_touchpads)
      palm_detectors = remapper.instance_variable_get(:@palm_detectors)
      expect(palm_detectors.keys).to include(new_touchpad)
    end

    it "recreates virtual touchpad" do
      expect(remapper).to receive(:create_virtual_touchpad)
      remapper.send(:reload_touchpads)
    end

    it "logs reconnection info" do
      expect(Fusuma::MultiLogger).to receive(:info).with(/Touchpad reconnected/)
      remapper.send(:reload_touchpads)
    end
  end

  describe Fusuma::Plugin::Remap::TouchpadRemapper::PalmDetection do
    let(:touchpad) do
      instance_double(
        "Revdev::EventDevice",
        absinfo_for_axis: ->(axis) {
          case axis
          when Revdev::ABS_MT_POSITION_X
            {absmax: 1000}
          when Revdev::ABS_MT_POSITION_Y
            {absmax: 1000}
          end
        }
      )
    end

    before do
      allow(touchpad).to receive(:absinfo_for_axis).with(Revdev::ABS_MT_POSITION_X).and_return({absmax: 1000})
      allow(touchpad).to receive(:absinfo_for_axis).with(Revdev::ABS_MT_POSITION_Y).and_return({absmax: 1000})
    end

    let(:palm_detection) { described_class.new(touchpad) }

    describe "#palm?" do
      context "with touch in center area" do
        it "returns true (valid touch)" do
          touch_state = {X: 500, Y: 500}
          expect(palm_detection.palm?(touch_state)).to be true
        end
      end

      context "with touch on left edge (palm area)" do
        it "returns false (palm detected)" do
          touch_state = {X: 100, Y: 500} # 10% from left edge
          expect(palm_detection.palm?(touch_state)).to be false
        end
      end

      context "with touch on right edge (palm area)" do
        it "returns false (palm detected)" do
          touch_state = {X: 900, Y: 500} # 10% from right edge
          expect(palm_detection.palm?(touch_state)).to be false
        end
      end

      context "with touch on bottom edge (palm area)" do
        it "returns true (bottom is valid touch area)" do
          touch_state = {X: 500, Y: 900} # 10% from bottom
          expect(palm_detection.palm?(touch_state)).to be true
        end
      end

      context "with missing coordinates" do
        it "returns false when X is nil" do
          touch_state = {X: nil, Y: 500}
          expect(palm_detection.palm?(touch_state)).to be false
        end

        it "returns false when Y is nil" do
          touch_state = {X: 500, Y: nil}
          expect(palm_detection.palm?(touch_state)).to be false
        end
      end
    end
  end
end
