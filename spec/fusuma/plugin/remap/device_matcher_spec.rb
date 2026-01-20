# frozen_string_literal: true

require "spec_helper"
require "fusuma/plugin/remap/device_matcher"
require "fusuma/config"

RSpec.describe Fusuma::Plugin::Remap::DeviceMatcher do
  let(:matcher) { described_class.new }

  # Stub for collecting device patterns from config
  def stub_config_with_device_patterns(patterns)
    keymap = patterns.map do |pattern|
      {context: {device: pattern}, remap: {}}
    end
    allow(Fusuma::Config.instance).to receive(:keymap).and_return(keymap)
  end

  describe "#match" do
    context "when device patterns exist in config" do
      before do
        stub_config_with_device_patterns(["HHKB", "AT Translated"])
      end

      context "when device name matches a pattern" do
        it "returns the matched pattern" do
          expect(matcher.match("PFU HHKB-Hybrid")).to eq("HHKB")
        end

        it "matches by partial match" do
          expect(matcher.match("AT Translated Set 2 keyboard")).to eq("AT Translated")
        end

        it "matches case-insensitively" do
          expect(matcher.match("pfu hhkb-hybrid")).to eq("HHKB")
        end
      end

      context "when device name does not match any pattern" do
        it "returns nil" do
          expect(matcher.match("Logitech USB Keyboard")).to be_nil
        end
      end

      context "when device name is nil" do
        it "returns nil" do
          expect(matcher.match(nil)).to be_nil
        end
      end
    end

    context "when no device patterns in config" do
      before do
        stub_config_with_device_patterns([])
      end

      it "returns nil" do
        expect(matcher.match("PFU HHKB-Hybrid")).to be_nil
      end
    end

    context "when config is nil (no config file)" do
      before do
        allow(Fusuma::Config.instance).to receive(:keymap).and_return(nil)
      end

      it "returns nil" do
        expect(matcher.match("PFU HHKB-Hybrid")).to be_nil
      end
    end
  end

  describe "pattern caching" do
    it "collects patterns only once" do
      expect(Fusuma::Config.instance).to receive(:keymap)
        .once
        .and_return([{context: {device: "HHKB"}, remap: {}}])

      matcher.match("HHKB")
      matcher.match("HHKB")
    end
  end
end
