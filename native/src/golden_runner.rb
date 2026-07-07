# frozen_string_literal: true

require_relative "control_parser"
require_relative "ffi"
require_relative "remap_core"

parser = ControlParser.new
core = RemapCore.new
device = "default"

loop do
  n = SHIM.shim_stdin_fill
  break if n == 0
  raise "stdin read failed: " + n.to_s if n < 0

  while SHIM.shim_stdin_pending == 1
    line = SHIM.shim_stdin_readline
    next if line.empty?

    msg = parser.parse(line)
    if msg.type == "mapping"
      device = msg.device
      core.update_mapping(msg.device, msg.layer_token, msg.entries)
    elsif msg.type == "event"
      result = core.process(device, msg.event_type, msg.code, msg.value)
      result.events.each do |event_line|
        next if event_line.empty?

        parts = event_line.split(",")
        puts "{\"t\":\"emit\",\"type\":" + parts[0] +
          ",\"code\":" + parts[1] +
          ",\"value\":" + parts[2] + "}"
      end
      result.lines.each { |out| puts out }
    end
  end
end
