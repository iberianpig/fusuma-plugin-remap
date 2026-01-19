# frozen_string_literal: true

require "spec_helper"
require "fusuma/plugin/remap/layer_manager"
require "fusuma/config"

RSpec.describe Fusuma::Plugin::Remap::LayerManager do
  let(:manager) { described_class.instance }

  before do
    # Reset singleton state for each test
    manager.instance_variable_set(:@layers, {})
    manager.instance_variable_set(:@merged_layers, nil)
  end

  describe "CONTEXT_PRIORITIES" do
    it "defines device with priority 1" do
      expect(described_class::CONTEXT_PRIORITIES[:device]).to eq(1)
    end

    it "defines thumbsense with priority 2" do
      expect(described_class::CONTEXT_PRIORITIES[:thumbsense]).to eq(2)
    end

    it "defines application with priority 3" do
      expect(described_class::CONTEXT_PRIORITIES[:application]).to eq(3)
    end

    it "follows priority order: device < thumbsense < application" do
      priorities = described_class::CONTEXT_PRIORITIES
      expect(priorities[:device]).to be < priorities[:thumbsense]
      expect(priorities[:thumbsense]).to be < priorities[:application]
    end
  end

  describe "device context" do
    # Helper to set up config search results based on context
    def stub_config_for_contexts(context_mappings)
      allow(Fusuma::Config::Searcher).to receive(:with_context) do |context, &block|
        result = context_mappings[context]
        if result
          allow(Fusuma::Config).to receive(:search).and_return(result)
        else
          allow(Fusuma::Config).to receive(:search).and_return(nil)
        end
        block.call
      end
    end

    context "with default + device contexts" do
      let(:default_mapping) { {"capslock" => "leftctrl"} }
      let(:device_mapping) { {"leftctrl" => "leftmeta"} }

      before do
        stub_config_for_contexts(
          {} => default_mapping,
          {device: "HHKB"} => device_mapping
        )
      end

      it "merges default and device mappings" do
        result = manager.find_merged_mapping({device: "HHKB"})
        expect(result).to include(CAPSLOCK: "leftctrl")
        expect(result).to include(LEFTCTRL: "leftmeta")
      end
    end

    context "with device + thumbsense contexts" do
      let(:device_mapping) { {"a" => "device_value"} }
      let(:thumbsense_mapping) { {"a" => "thumbsense_value"} }

      before do
        stub_config_for_contexts(
          {device: "HHKB"} => device_mapping,
          {thumbsense: true} => thumbsense_mapping
        )
      end

      it "thumbsense overrides device for same key" do
        layer = {device: "HHKB", thumbsense: true}
        result = manager.find_merged_mapping(layer)
        expect(result[:A]).to eq("thumbsense_value")
      end
    end

    context "with device + thumbsense + application contexts" do
      let(:device_mapping) { {"a" => "device"} }
      let(:thumbsense_mapping) { {"a" => "thumbsense"} }
      let(:application_mapping) { {"a" => "application"} }

      before do
        stub_config_for_contexts(
          {device: "HHKB"} => device_mapping,
          {thumbsense: true} => thumbsense_mapping,
          {application: "Chrome"} => application_mapping
        )
      end

      it "overrides with priority order: application > thumbsense > device" do
        layer = {device: "HHKB", thumbsense: true, application: "Chrome"}
        result = manager.find_merged_mapping(layer)
        expect(result[:A]).to eq("application")
      end
    end
  end

  describe "#find_merged_mapping" do
    # Helper to set up config search results based on context
    def stub_config_for_contexts(context_mappings)
      allow(Fusuma::Config::Searcher).to receive(:with_context) do |context, &block|
        # Find matching context
        result = context_mappings[context]
        if result
          allow(Fusuma::Config).to receive(:search).and_return(result)
        else
          allow(Fusuma::Config).to receive(:search).and_return(nil)
        end
        block.call
      end
    end

    context "with only default context" do
      let(:default_mapping) { {"leftctrl+a" => "home", "leftctrl+e" => "end"} }

      before do
        stub_config_for_contexts({} => default_mapping)
      end

      it "returns default mapping when layer is empty" do
        result = manager.find_merged_mapping({})
        expect(result).to eq({"LEFTCTRL+A": "home", "LEFTCTRL+E": "end"})
      end
    end

    context "with only thumbsense context" do
      let(:thumbsense_mapping) { {"j" => "btn_left", "k" => "btn_right"} }

      before do
        stub_config_for_contexts({thumbsense: true} => thumbsense_mapping)
      end

      it "returns thumbsense mapping when thumbsense layer is active" do
        result = manager.find_merged_mapping({thumbsense: true})
        expect(result).to eq({J: "btn_left", K: "btn_right"})
      end
    end

    context "with default + thumbsense contexts" do
      let(:default_mapping) { {"leftctrl+a" => "home", "leftctrl+e" => "end"} }
      let(:thumbsense_mapping) { {"j" => "btn_left"} }

      before do
        stub_config_for_contexts(
          {} => default_mapping,
          {thumbsense: true} => thumbsense_mapping
        )
      end

      it "merges default and thumbsense mappings" do
        result = manager.find_merged_mapping({thumbsense: true})
        expect(result).to include("LEFTCTRL+A": "home")
        expect(result).to include("LEFTCTRL+E": "end")
        expect(result).to include(J: "btn_left")
      end
    end

    context "with default + application contexts" do
      let(:default_mapping) { {"leftctrl+a" => "home", "leftctrl+e" => "end"} }
      let(:application_mapping) { {"leftctrl+a" => "leftctrl+a"} } # Override default

      before do
        stub_config_for_contexts(
          {} => default_mapping,
          {application: "Google-chrome"} => application_mapping
        )
      end

      it "application overrides default for same key" do
        result = manager.find_merged_mapping({application: "Google-chrome"})
        expect(result[:"LEFTCTRL+A"]).to eq("leftctrl+a")
        expect(result[:"LEFTCTRL+E"]).to eq("end")
      end
    end

    context "with default + thumbsense + application contexts" do
      let(:default_mapping) { {"leftctrl+a" => "home", "leftctrl+e" => "end"} }
      let(:thumbsense_mapping) { {"j" => "btn_left"} }
      let(:application_mapping) { {"leftctrl+a" => "leftctrl+a"} }

      before do
        stub_config_for_contexts(
          {} => default_mapping,
          {thumbsense: true} => thumbsense_mapping,
          {application: "Google-chrome"} => application_mapping
        )
      end

      it "merges all contexts with correct priority" do
        layer = {thumbsense: true, application: "Google-chrome"}
        result = manager.find_merged_mapping(layer)

        # application (priority 2) overrides default (priority 0)
        expect(result[:"LEFTCTRL+A"]).to eq("leftctrl+a")
        # default is inherited
        expect(result[:"LEFTCTRL+E"]).to eq("end")
        # thumbsense is inherited
        expect(result[:J]).to eq("btn_left")
      end
    end

    context "with key override scenario" do
      let(:default_mapping) { {"a" => "b"} }
      let(:thumbsense_mapping) { {"a" => "c"} }
      let(:application_mapping) { {"a" => "d"} }

      before do
        stub_config_for_contexts(
          {} => default_mapping,
          {thumbsense: true} => thumbsense_mapping,
          {application: "Google-chrome"} => application_mapping
        )
      end

      it "higher priority context wins for same key" do
        layer = {thumbsense: true, application: "Google-chrome"}
        result = manager.find_merged_mapping(layer)

        # application (priority 2) wins over thumbsense (priority 1) and default (priority 0)
        expect(result[:A]).to eq("d")
      end

      it "thumbsense wins over default when only thumbsense is active" do
        result = manager.find_merged_mapping({thumbsense: true})
        expect(result[:A]).to eq("c")
      end
    end

    context "with complete match (multiple keys)" do
      let(:default_mapping) { {"a" => "default"} }
      let(:thumbsense_mapping) { {"a" => "thumbsense"} }
      let(:application_mapping) { {"a" => "application"} }
      let(:complete_mapping) { {"a" => "complete"} }

      before do
        stub_config_for_contexts(
          {} => default_mapping,
          {thumbsense: true} => thumbsense_mapping,
          {application: "Google-chrome"} => application_mapping,
          {thumbsense: true, application: "Google-chrome"} => complete_mapping
        )
      end

      it "complete match has highest priority" do
        layer = {thumbsense: true, application: "Google-chrome"}
        result = manager.find_merged_mapping(layer)

        # Complete match (priority 100) wins over everything
        expect(result[:A]).to eq("complete")
      end
    end

    context "with empty mapping" do
      before do
        stub_config_for_contexts({})
      end

      it "returns empty hash when no mappings found" do
        result = manager.find_merged_mapping({})
        expect(result).to eq({})
      end

      it "returns empty hash for unknown context" do
        result = manager.find_merged_mapping({unknown: true})
        expect(result).to eq({})
      end
    end

    context "caching behavior" do
      let(:default_mapping) { {"a" => "b"} }

      before do
        stub_config_for_contexts({} => default_mapping)
      end

      it "caches merged mapping for same layer" do
        layer = {}
        first_result = manager.find_merged_mapping(layer)
        second_result = manager.find_merged_mapping(layer)

        expect(first_result).to equal(second_result) # Same object reference
      end

      it "computes different result for different layer" do
        result1 = manager.find_merged_mapping({})

        stub_config_for_contexts({thumbsense: true} => {"j" => "btn_left"})
        result2 = manager.find_merged_mapping({thumbsense: true})

        expect(result1).not_to eq(result2)
      end
    end

    context "with unknown context type" do
      let(:default_mapping) { {"a" => "default"} }
      let(:custom_mapping) { {"a" => "custom"} }

      before do
        stub_config_for_contexts(
          {} => default_mapping,
          {custom_context: "value"} => custom_mapping
        )
      end

      it "uses default priority 1 for unknown context types" do
        result = manager.find_merged_mapping({custom_context: "value"})
        # custom_context has priority 1 (same as thumbsense default)
        # It overrides default (priority 0)
        expect(result[:A]).to eq("custom")
      end
    end
  end

  describe "#find_mapping (original method)" do
    let(:mapping) { {"a" => "b"} }

    before do
      allow(Fusuma::Config::Searcher).to receive(:find_context).and_yield
      allow(Fusuma::Config).to receive(:search).and_return(mapping)
    end

    it "returns mapping for exact context match" do
      result = manager.find_mapping({thumbsense: true})
      expect(result).to eq({A: "b"})
    end
  end
end
