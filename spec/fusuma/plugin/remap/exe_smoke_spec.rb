require "spec_helper"

RSpec.describe "Executable smoke tests" do
  describe "fusuma-remap" do
    it "prints version with --version flag" do
      output = `bundle exec ruby exe/fusuma-remap --version 2>&1`
      expect($?.success?).to be true
      expect(output.strip).to match(/\Afusuma-remap \d+\.\d+\.\d+\z/)
    end
  end

  describe "fusuma-touchpad-remap" do
    it "prints version with --version flag" do
      output = `bundle exec ruby exe/fusuma-touchpad-remap --version 2>&1`
      expect($?.success?).to be true
      expect(output.strip).to match(/\Afusuma-touchpad-remap \d+\.\d+\.\d+\z/)
    end
  end
end
