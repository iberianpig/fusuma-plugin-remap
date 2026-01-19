# frozen_string_literal: true

require "spec_helper"
require "fusuma/plugin/remap/modifier_state"

RSpec.describe Fusuma::Plugin::Remap::ModifierState do
  let(:state) { described_class.new }

  describe "#modifier?" do
    %w[LEFTCTRL RIGHTCTRL LEFTALT RIGHTALT LEFTSHIFT RIGHTSHIFT LEFTMETA RIGHTMETA].each do |key|
      it "#{key} is a modifier key" do
        expect(state.modifier?(key)).to be true
      end
    end

    %w[A X SPACE ENTER].each do |key|
      it "#{key} is not a modifier key" do
        expect(state.modifier?(key)).to be false
      end
    end
  end

  describe "#update" do
    context "when pressing a modifier key" do
      it "becomes pressed state on press (value=1)" do
        state.update("LEFTCTRL", 1)
        expect(state.pressed_modifiers).to include("LEFTCTRL")
      end

      it "releases pressed state on release (value=0)" do
        state.update("LEFTCTRL", 1)
        state.update("LEFTCTRL", 0)
        expect(state.pressed_modifiers).not_to include("LEFTCTRL")
      end

      it "does not change state on repeat (value=2)" do
        state.update("LEFTCTRL", 1)
        state.update("LEFTCTRL", 2)
        expect(state.pressed_modifiers).to include("LEFTCTRL")
      end
    end

    context "when pressing a normal key" do
      it "does not change state" do
        state.update("A", 1)
        expect(state.pressed_modifiers).to be_empty
      end
    end

    context "when pressing multiple modifier keys" do
      it "tracks all modifier keys" do
        state.update("LEFTCTRL", 1)
        state.update("LEFTSHIFT", 1)
        expect(state.pressed_modifiers).to include("LEFTCTRL", "LEFTSHIFT")
      end
    end
  end

  describe "#pressed_modifiers" do
    it "is empty initially" do
      expect(state.pressed_modifiers).to be_empty
    end

    it "returns pressed modifiers sorted alphabetically" do
      state.update("LEFTSHIFT", 1)
      state.update("LEFTCTRL", 1)
      expect(state.pressed_modifiers).to eq(%w[LEFTCTRL LEFTSHIFT])
    end
  end

  describe "#current_combination" do
    context "when no modifier is pressed" do
      it "returns the key as-is" do
        expect(state.current_combination("X")).to eq("X")
      end
    end

    context "when LEFTCTRL is pressed" do
      before { state.update("LEFTCTRL", 1) }

      it "returns LEFTCTRL+X when X is pressed" do
        expect(state.current_combination("X")).to eq("LEFTCTRL+X")
      end

      it "returns modifier key as-is when pressed" do
        expect(state.current_combination("LEFTCTRL")).to eq("LEFTCTRL")
      end
    end

    context "when multiple modifiers are pressed" do
      before do
        state.update("LEFTSHIFT", 1)
        state.update("LEFTCTRL", 1)
      end

      it "returns sorted modifiers + key" do
        expect(state.current_combination("X")).to eq("LEFTCTRL+LEFTSHIFT+X")
      end
    end
  end

  describe "#reset" do
    it "clears all pressed states" do
      state.update("LEFTCTRL", 1)
      state.update("LEFTSHIFT", 1)
      state.reset
      expect(state.pressed_modifiers).to be_empty
    end
  end
end
