# frozen_string_literal: true

require_relative "constants"
require_relative "control_parser"
require_relative "ffi"
require_relative "json_writer"
require_relative "remap_core"
require_relative "uinput_keyboard"

class SourceDevice
  attr_reader :path, :fd, :name

  def initialize(path, fd, name)
    @path = path
    @fd = fd
    @name = name
  end
end

class EventLoop
  MAX_PARSE_ERROR_LENGTH = 200

  def initialize
    @parser = ControlParser.new
    @core = RemapCore.new
    @uinput = UinputKeyboard.new
    @devices = []
    @configured = false
    @emergency_keys = Const::DEFAULT_EMERGENCY_KEYS
    @last_key_code = -1
    @last_key_value = 0
  end

  def run
    loop do
      rc = SHIM.shim_wait_any(poll_fds, poll_fds.length, 3000)
      if rc == 0
        break unless process_stdin
      elsif rc > 0
        process_device_index(rc - 1)
      elsif rc < -1
        fatal("poll failed: " + rc.to_s)
        break
      end
    end
  ensure
    cleanup
  end

  private

  def poll_fds
    fds = [0]
    @devices.each { |device| fds.push(device.fd) }
    fds
  end

  def process_stdin
    n = SHIM.shim_stdin_fill
    return false if n == 0
    if n == Const::ENOBUFS_NEG
      $stderr.puts "ignored oversized control line"
      return true
    end
    if n < 0
      fatal("stdin read failed: " + n.to_s)
      return false
    end

    while SHIM.shim_stdin_pending == 1
      line = SHIM.shim_stdin_readline
      msg = parse_control(line)
      process_control(msg) unless msg.nil?
    end
    true
  rescue => e
    fatal(e.message)
    false
  end

  def parse_control(line)
    @parser.parse(line)
  rescue => e
    $stderr.puts "ignored invalid control line: " + truncate_message(e.message)
    nil
  end

  def truncate_message(message)
    return message if message.length <= MAX_PARSE_ERROR_LENGTH

    message[0, MAX_PARSE_ERROR_LENGTH] + "..."
  end

  def process_control(msg)
    if msg.type == "config"
      configure(msg)
    elsif msg.type == "attach"
      attach(msg.path)
    elsif msg.type == "detach"
      detach(msg.path)
    elsif msg.type == "mapping"
      @core.update_mapping(msg.device, msg.layer_token, msg.entries)
    else
      $stderr.puts "unknown control message: " + msg.type
    end
  end

  def configure(msg)
    name = msg.vname.empty? ? Const::VIRTUAL_KEYBOARD_NAME : msg.vname
    bustype = msg.bustype == 0 ? Const::BUS_VIRTUAL : msg.bustype
    vendor = msg.vendor == 0 ? Const::DEFAULT_VENDOR : msg.vendor
    product = msg.product == 0 ? Const::DEFAULT_PRODUCT : msg.product
    version = msg.version == 0 ? Const::DEFAULT_VERSION : msg.version

    @emergency_keys = msg.emergency.empty? ? Const::DEFAULT_EMERGENCY_KEYS : msg.emergency
    @uinput.create(name, bustype, vendor, product, version)
    @configured = true
  end

  def attach(path)
    unless @configured
      attach_failed(path, "not configured")
      return
    end
    existing = find_device(path)
    unless existing.nil?
      emit_attached(existing)
      return
    end

    fd = SHIM.shim_open_device(path)
    if fd < 0
      $stderr.puts "open failed: " + path + " rc=" + fd.to_s
      attach_failed(path, "open failed: " + fd.to_s)
      return
    end

    unless wait_release_all_keys(fd)
      SHIM.shim_close(fd)
      attach_failed(path, "wait release failed")
      return
    end

    rc = SHIM.shim_grab(fd)
    if rc < 0
      $stderr.puts "grab failed: " + path + " rc=" + rc.to_s
      SHIM.shim_close(fd)
      attach_failed(path, "grab failed: " + rc.to_s)
      return
    end

    name = SHIM.shim_device_name(fd)
    device = SourceDevice.new(path, fd, name)
    @devices.push(device)
    emit_attached(device)
    $stderr.puts "attached keyboard: " + name + " (" + path + ")"
  end

  def emit_attached(device)
    puts "{\"t\":\"attached\",\"path\":" + JsonWriter.quote(device.path) +
      ",\"device\":" + JsonWriter.quote(device.name) + "}"
    SHIM.shim_flush
  end

  def attach_failed(path, message)
    puts "{\"t\":\"attach_failed\",\"path\":" + JsonWriter.quote(path) +
      ",\"message\":" + JsonWriter.quote(message) + "}"
    SHIM.shim_flush
  end

  def detach(path)
    kept = []
    @devices.each do |device|
      if device.path == path
        close_device(device)
        puts "{\"t\":\"detached\",\"path\":" + JsonWriter.quote(path) + "}"
        SHIM.shim_flush
      else
        kept.push(device)
      end
    end
    @devices = kept
  end

  def find_device(path)
    @devices.each do |device|
      return device if device.path == path
    end
    nil
  end

  def process_device_index(index)
    device = @devices[index]
    return if device.nil?

    rc = SHIM.shim_read_event(device.fd, SHIM.ev_buf)
    if rc < 0
      detached_path = device.path
      detach(detached_path)
      return
    end

    type = SHIM.ev_type(SHIM.ev_buf)
    code = SHIM.ev_code(SHIM.ev_buf)
    value = SHIM.ev_value(SHIM.ev_buf)

    if type == Const::EV_KEY && emergency_pressed?(code, value)
      $stderr.puts "emergency ungrab pressed"
      cleanup
      exit 0
    end

    result = @core.process(device.name, type, code, value)
    result.events.each do |event_line|
      next if event_line.empty?

      parts = event_line.split(",")
      rc = @uinput.emit(parts[0].to_i, parts[1].to_i, parts[2].to_i)
      $stderr.puts "emit failed: " + rc.to_s if rc < 0
    end
    result.lines.each { |line| puts line }
    SHIM.shim_flush

    @last_key_code = code if type == Const::EV_KEY
    @last_key_value = value if type == Const::EV_KEY
  end

  def emergency_pressed?(code, value)
    return false if @emergency_keys.length != 2
    return false if value == 0

    first = @core.key_to_code(@emergency_keys[0])
    second = @core.key_to_code(@emergency_keys[1])
    @last_key_code == first && @last_key_value != 0 && code == second
  end

  def wait_release_all_keys(fd)
    loop do
      rc = SHIM.shim_all_keys_released(fd)
      return true if rc == 1
      return false if rc < 0

      read_rc = SHIM.shim_read_event(fd, SHIM.ev_buf)
      return false if read_rc < 0
    end
  end

  def close_device(device)
    SHIM.shim_ungrab(device.fd)
    SHIM.shim_close(device.fd)
  end

  def cleanup
    @devices.each { |device| close_device(device) }
    @devices = []
    @uinput.destroy
  end

  def fatal(message)
    puts "{\"t\":\"fatal\",\"message\":" + JsonWriter.quote(message) + "}"
    SHIM.shim_flush
    $stderr.puts "fatal: " + message
  end
end
