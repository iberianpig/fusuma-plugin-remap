# frozen_string_literal: true

require "open3"
require "spec_helper"
require "control_parser"
require "remap_core"

RSpec.describe "native golden runner" do
  let(:repo_root) { File.expand_path("../..", __dir__) }
  let(:input) do
    <<~JSONL
      {"t":"mapping","device":"HHKB","layer":"{\\"thumbsense\\":true}","entries":[["CAPSLOCK","simple","LEFTCTRL"],["LEFTCTRL+A","combo","HOME"],["X","seq","LEFTSHIFT+HOME|DELETE"],["Y","swallow",""]]}
      {"t":"event","etype":1,"code":58,"value":1}
      {"t":"event","etype":1,"code":30,"value":1}
      {"t":"event","etype":1,"code":30,"value":0}
      {"t":"event","etype":1,"code":58,"value":0}
      {"t":"event","etype":1,"code":45,"value":1}
      {"t":"event","etype":1,"code":21,"value":1}
      {"t":"event","etype":2,"code":1,"value":5}
      {"t":"mapping","device":"HHKB","layer":"{\\"review\\":1}","entries":[["A","simple","B"]]}
      {"t":"event","etype":1,"code":30,"value":1}
      {"t":"event","etype":1,"code":30,"value":2}
      {"t":"mapping","device":"HHKB","layer":"{\\"review\\":2}","entries":[["A","simple","C"]]}
      {"t":"event","etype":1,"code":30,"value":0}
      {"t":"event","etype":1,"code":30,"value":1}
    JSONL
  end

  def capture(*cmd, stdin_data:)
    stdout, stderr, status = Open3.capture3(*cmd, stdin_data: stdin_data, chdir: repo_root)
    expect(status).to be_success, stderr
    stdout
  end

  def cruby_output(input)
    parser = ControlParser.new
    core = RemapCore.new
    device = "default"
    lines = []

    input.each_line do |line|
      msg = parser.parse(line.chomp)
      if msg.type == "mapping"
        device = msg.device
        core.update_mapping(msg.device, msg.layer_token, msg.entries)
      elsif msg.type == "event"
        result = core.process(device, msg.event_type, msg.code, msg.value)
        result.events.each do |event_line|
          next if event_line.empty?

          type, code, value = event_line.split(",")
          lines << "{\"t\":\"emit\",\"type\":#{type},\"code\":#{code},\"value\":#{value}}"
        end
        result.lines.each { |out| lines << out }
      end
    end

    lines.join("\n") + "\n"
  end

  it "matches CRuby and Spinel output" do
    spinel = File.expand_path("~/ghq/github.com/matz/spinel/spinel")
    skip "spinel is not available" unless File.executable?(spinel)

    make_stdout, make_stderr, make_status = Open3.capture3("make", "-C", "native", "golden", chdir: repo_root)
    expect(make_status).to be_success, make_stdout + make_stderr

    spinel_output = capture("native/build/fusuma-remap-golden", stdin_data: input)

    expect(spinel_output).to eq(cruby_output(input))
  end
end
