# frozen_string_literal: true

require "json"
require "stringio"
require "spec_helper"

require "fusuma/plugin/remap/native_keyboard_controller"

RSpec.describe Fusuma::Plugin::Remap::NativeKeyboardController do
  let(:path) { "/dev/input/event4" }
  let(:writer) { StringIO.new }
  let(:fusuma_writer) { StringIO.new }
  let(:layer_manager) do
    instance_double(
      Fusuma::Plugin::Remap::LayerManager,
      find_merged_mapping: {},
      normalize_mapping: [["A", "simple", "B"]]
    )
  end
  let(:device_matcher) { instance_double(Fusuma::Plugin::Remap::DeviceMatcher, match: nil) }
  let(:controller) do
    described_class.allocate.tap do |instance|
      instance.instance_variable_set(:@writer, writer)
      instance.instance_variable_set(:@fusuma_writer, fusuma_writer)
      instance.instance_variable_set(:@layer_manager, layer_manager)
      instance.instance_variable_set(:@device_matcher, device_matcher)
      instance.instance_variable_set(:@current_layer, {"review" => true})
      instance.instance_variable_set(:@known_devices, {})
      instance.instance_variable_set(:@pending_devices, {})
      instance.instance_variable_set(:@attached_devices, {})
    end
  end

  describe "#attach_succeeded" do
    it "moves the device to attached and pushes mapping for the native device name" do
      controller.instance_variable_get(:@pending_devices)[path] = {name: "Configured HHKB", path: path}

      controller.send(:attach_succeeded, path, "Native HHKB")

      attached = controller.instance_variable_get(:@attached_devices)
      message = JSON.parse(writer.string.lines.last)

      expect(attached[path]).to include(name: "Configured HHKB", native_name: "Native HHKB")
      expect(controller.instance_variable_get(:@pending_devices)).not_to have_key(path)
      expect(message).to include(
        "t" => "mapping",
        "device" => "Native HHKB",
        "layer" => "{\"review\":true}",
        "entries" => [["A", "simple", "B"]]
      )
    end
  end

  describe "#process_native_message" do
    it "forwards only key lines to fusuma" do
      line = {t: "key", key: "A", status: 1, layer: {}}.to_json + "\n"

      controller.send(:process_native_message, JSON.parse(line), line)

      expect(fusuma_writer.string).to eq(line)
      expect(writer.string).to be_empty
    end

    it "handles attach lifecycle messages inside the controller" do
      controller.instance_variable_get(:@pending_devices)[path] = {name: "Configured HHKB", path: path}
      line = {t: "attached", path: path, device: "Native HHKB"}.to_json + "\n"

      controller.send(:process_native_message, JSON.parse(line), line)

      attached = controller.instance_variable_get(:@attached_devices)
      message = JSON.parse(writer.string.lines.last)

      expect(fusuma_writer.string).to be_empty
      expect(attached[path]).to include(name: "Configured HHKB", native_name: "Native HHKB")
      expect(message["t"]).to eq("mapping")
      expect(message["device"]).to eq("Native HHKB")
    end

    it "does not forward fatal messages to fusuma" do
      line = {t: "fatal", message: "parse failed"}.to_json + "\n"

      controller.send(:process_native_message, JSON.parse(line), line)

      expect(fusuma_writer.string).to be_empty
      expect(writer.string).to be_empty
    end
  end

  describe "#attach_failed" do
    it "forgets pending and attached state so polling can retry" do
      controller.instance_variable_get(:@pending_devices)[path] = {name: "HHKB", path: path}
      controller.instance_variable_get(:@attached_devices)[path] = {name: "HHKB", path: path}

      controller.send(:attach_failed, path)

      expect(controller.instance_variable_get(:@pending_devices)).not_to have_key(path)
      expect(controller.instance_variable_get(:@attached_devices)).not_to have_key(path)
    end
  end

  describe "#detached" do
    it "forgets pending and attached state so polling can reattach" do
      controller.instance_variable_get(:@pending_devices)[path] = {name: "HHKB", path: path}
      controller.instance_variable_get(:@attached_devices)[path] = {name: "HHKB", path: path}

      controller.send(:detached, path)

      expect(controller.instance_variable_get(:@pending_devices)).not_to have_key(path)
      expect(controller.instance_variable_get(:@attached_devices)).not_to have_key(path)
    end
  end
end
