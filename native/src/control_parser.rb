# frozen_string_literal: true

require "strscan"
require_relative "map_entry"

class ControlMessage
  attr_reader :type, :path, :device, :layer_token, :entries
  attr_reader :emergency, :vname, :bustype, :vendor, :product, :version
  attr_reader :event_type, :code, :value

  def initialize
    @type = ""
    @path = ""
    @device = ""
    @layer_token = "null"
    @entries = {}
    @emergency = []
    @vname = ""
    @bustype = 0
    @vendor = 0
    @product = 0
    @version = 0
    @event_type = 0
    @code = 0
    @value = 0
  end

  def set_type(value)
    @type = value
  end

  def set_path(value)
    @path = value
  end

  def set_device(value)
    @device = value
  end

  def set_layer_token(value)
    @layer_token = value
  end

  def set_entries(value)
    @entries = value
  end

  def set_emergency(value)
    @emergency = value
  end

  def set_vname(value)
    @vname = value
  end

  def set_bustype(value)
    @bustype = value
  end

  def set_vendor(value)
    @vendor = value
  end

  def set_product(value)
    @product = value
  end

  def set_version(value)
    @version = value
  end

  def set_event_type(value)
    @event_type = value
  end

  def set_code(value)
    @code = value
  end

  def set_value(value)
    @value = value
  end
end

class ControlParser
  def parse(line)
    s = StringScanner.new(line)
    msg = ControlMessage.new
    expect(s, "{")

    loop do
      key = parse_string(s)
      expect(s, ":")

      if key == "t"
        msg.set_type(parse_string(s))
      elsif key == "path"
        msg.set_path(parse_string(s))
      elsif key == "device"
        msg.set_device(parse_string(s))
      elsif key == "layer"
        msg.set_layer_token(parse_string(s))
      elsif key == "entries"
        msg.set_entries(parse_entries(s))
      elsif key == "emergency"
        msg.set_emergency(parse_string_array(s))
      elsif key == "vname"
        msg.set_vname(parse_string(s))
      elsif key == "bustype"
        msg.set_bustype(parse_int(s))
      elsif key == "vendor"
        msg.set_vendor(parse_int(s))
      elsif key == "product"
        msg.set_product(parse_int(s))
      elsif key == "version"
        msg.set_version(parse_int(s))
      elsif key == "etype"
        msg.set_event_type(parse_int(s))
      elsif key == "code"
        msg.set_code(parse_int(s))
      elsif key == "value"
        msg.set_value(parse_int(s))
      else
        raise "unknown control key: " + key
      end

      break unless consume_comma(s)
    end

    expect(s, "}")
    msg
  end

  private

  def skip_ws(s)
    s.scan(/\s*/)
  end

  def consume_comma(s)
    skip_ws(s)
    s.scan(/,/) ? true : false
  end

  def expect(s, ch)
    skip_ws(s)
    c = s.getch
    raise "expected " + ch + " at " + s.rest if c != ch
  end

  def parse_string(s)
    skip_ws(s)
    raise "expected string at " + s.rest unless s.scan(/"/)

    out = ""
    loop do
      c = s.getch
      raise "unterminated string" if c.nil?

      if c == "\\"
        nc = s.getch
        if nc == "n"
          out += "\n"
        elsif nc == "t"
          out += "\t"
        elsif nc == "r"
          out += "\r"
        elsif !nc.nil?
          out += nc
        end
      elsif c == "\""
        break
      else
        out += c
      end
    end
    out
  end

  def parse_int(s)
    skip_ws(s)
    sign = 1
    if s.scan(/-/)
      sign = -1
    end

    digits = s.scan(/[0-9]+/)
    raise "expected integer at " + s.rest if digits.nil?

    sign * digits.to_i
  end

  def parse_string_array(s)
    values = []
    expect(s, "[")
    skip_ws(s)
    return values if s.scan(/\]/)

    loop do
      values.push(parse_string(s))
      skip_ws(s)
      break if s.scan(/\]/)
      expect(s, ",")
    end
    values
  end

  def parse_entries(s)
    entries = {}
    expect(s, "[")
    skip_ws(s)
    return entries if s.scan(/\]/)

    loop do
      expect(s, "[")
      from = parse_string(s)
      expect(s, ",")
      kind = parse_string(s)
      expect(s, ",")
      to_joined = parse_string(s)
      expect(s, "]")

      to = []
      unless to_joined.empty?
        to_joined.split("|").each { |value| to.push(value) }
      end
      entries[from] = MapEntry.new(kind, to)

      skip_ws(s)
      break if s.scan(/\]/)
      expect(s, ",")
    end

    entries
  end
end
