# frozen_string_literal: true

require "json"
require "revdev"
require "fusuma/device"
require_relative "device_matcher"
require_relative "device_selector"
require_relative "keyboard_remapper"

module Fusuma
  module Plugin
    module Remap
      class NativeKeyboardController
        DEVICE_CHECK_INTERVAL = 3

        attr_reader :reader, :pid

        def initialize(binary_path:, layer_manager:, config:)
          @binary_path = binary_path
          @layer_manager = layer_manager
          @config = config
          @device_matcher = DeviceMatcher.new
          @known_devices = {}
          @pending_devices = {}
          @attached_devices = {}
          @current_layer = @layer_manager.current_layer || {}
          @stop = false

          start_process
          start_control_thread
        end

        def shutdown
          @stop = true
          @control_thread&.kill
          @writer&.close unless @writer&.closed?
          @native_reader&.close unless @native_reader&.closed?
          @reader&.close unless @reader&.closed?
          @fusuma_writer&.close unless @fusuma_writer&.closed?
          Process.kill("TERM", @pid) if @pid
        rescue Errno::ESRCH, IOError
        ensure
          begin
            Process.wait(@pid) if @pid
          rescue Errno::ECHILD, Errno::ESRCH
          end
        end

        private

        def start_process
          ctrl_reader, @writer = IO.pipe
          @native_reader, child_stdout = IO.pipe
          @reader, @fusuma_writer = IO.pipe

          @pid = Process.spawn(@binary_path, in: ctrl_reader, out: child_stdout, err: :err)

          ctrl_reader.close
          child_stdout.close
        end

        def start_control_thread
          @control_thread = Thread.new do
            send_config
            poll_keyboards
            next_poll_at = monotonic_time + DEVICE_CHECK_INTERVAL

            until @stop
              timeout = next_poll_at - monotonic_time
              timeout = 0 if timeout.negative?
              ios = IO.select([@layer_manager.reader, @native_reader], nil, nil, timeout)
              ios&.first&.each { |io| process_ready_io(io) }

              if monotonic_time >= next_poll_at
                poll_keyboards
                next_poll_at = monotonic_time + DEVICE_CHECK_INTERVAL
              end
            end
          rescue IOError, Errno::EPIPE => e
            MultiLogger.error("Native remap controller stopped: #{e.message}") unless @stop
          rescue => e
            MultiLogger.error("Native remap controller failed: #{e.message}")
            MultiLogger.error(e.backtrace.join("\n")) if e.backtrace
          ensure
            begin
              @fusuma_writer&.close unless @fusuma_writer&.closed?
            rescue IOError
            end
          end
        end

        def monotonic_time
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end

        def process_ready_io(io)
          if io == @native_reader
            process_native_stdout
          elsif io == @layer_manager.reader
            process_layer_update
          end
        end

        def process_layer_update
          layer = @layer_manager.receive_layer
          return if layer.nil?

          @current_layer = layer
          push_all_mappings
        end

        def process_native_stdout
          line = @native_reader.gets
          raise EOFError, "native remapper closed stdout" if line.nil?

          data = JSON.parse(line)
          raise "native remapper output is not Hash : #{data}" unless data.is_a? Hash

          process_native_message(data, line)
        end

        def process_native_message(data, raw_line)
          case data["t"]
          when nil, "key"
            forward_to_fusuma(raw_line)
          when "hello"
            MultiLogger.info("Native keyboard remapper started: #{data["version"]}")
          when "attached"
            attach_succeeded(data["path"], data["device"])
          when "attach_failed"
            MultiLogger.warn("Keyboard attach failed: #{data["path"]}: #{data["message"]}")
            attach_failed(data["path"])
          when "detached"
            MultiLogger.warn("Keyboard detached: #{data["path"]}")
            detached(data["path"])
          when "fatal"
            MultiLogger.error("Native keyboard remapper fatal: #{data["message"]}")
          else
            MultiLogger.warn("Unknown native keyboard remapper message: #{data}")
          end
        end

        def forward_to_fusuma(line)
          @fusuma_writer.write(line.end_with?("\n") ? line : "#{line}\n")
          @fusuma_writer.flush
        end

        def send_config
          id = virtual_keyboard_id
          send_message(
            t: "config",
            emergency: emergency_keys,
            vname: KeyboardRemapper::VIRTUAL_KEYBOARD_NAME,
            bustype: id[:bustype],
            vendor: id[:vendor],
            product: id[:product],
            version: id[:version]
          )
        end

        def emergency_keys
          keys = @config[:emergency_ungrab_keys]&.split("+")
          return keys if keys&.size == 2

          KeyboardRemapper::DEFAULT_EMERGENCY_KEYBIND.split("+")
        end

        def virtual_keyboard_id
          touchpad = DeviceSelector.new(
            name_patterns: @config[:touchpad_name_patterns],
            device_type: :touchpad
          ).select(wait: false).first

          if touchpad.nil?
            MultiLogger.warn("No touchpad found: #{@config[:touchpad_name_patterns]}")
            MultiLogger.warn("Disable-while-typing feature will not work without a touchpad")
            return {bustype: Revdev::BUS_VIRTUAL, vendor: 1, product: 1, version: 1}
          end

          id = touchpad.device_id
          begin
            touchpad.file.close
          rescue IOError
          end
          {
            bustype: Revdev::BUS_I8042,
            vendor: id.vendor,
            product: id.product,
            version: id.version
          }
        end

        def poll_keyboards
          devices = matching_keyboards
          current_paths = devices.map { |device| device[:path] }

          (@attached_devices.keys - current_paths).each do |path|
            send_message(t: "detach", path: path)
            @attached_devices.delete(path)
            @pending_devices.delete(path)
          end

          devices.each do |device|
            next if @attached_devices.key?(device[:path])
            next if @pending_devices.key?(device[:path])

            @known_devices[device[:path]] = device
            @pending_devices[device[:path]] = device
            send_message(t: "attach", path: device[:path])
          end
        end

        def attach_succeeded(path, native_name)
          device = @pending_devices.delete(path) || @known_devices[path] || {name: native_name, path: path}
          @attached_devices[path] = device.merge(native_name: native_name)
          push_mapping(@attached_devices[path])
        end

        def attach_failed(path)
          @pending_devices.delete(path)
          @attached_devices.delete(path)
        end

        def detached(path)
          @pending_devices.delete(path)
          @attached_devices.delete(path)
        end

        def matching_keyboards
          Fusuma::Device.reset
          patterns = Array(@config[:keyboard_name_patterns])
          devices = Fusuma::Device.all.filter_map do |device|
            next if device.name == KeyboardRemapper::VIRTUAL_KEYBOARD_NAME
            next unless patterns.any? { |name| device.name =~ /#{name}/ }

            {name: device.name, path: "/dev/input/#{device.id}"}
          end

          MultiLogger.warn("No keyboard found: #{patterns}") if devices.empty? && @attached_devices.empty?
          devices
        end

        def push_all_mappings
          @attached_devices.each_value { |device| push_mapping(device) }
        end

        def push_mapping(device)
          matched_pattern = @device_matcher.match(device[:name])
          effective_layer = matched_pattern ? @current_layer.merge(device: matched_pattern) : @current_layer
          mapping = @layer_manager.find_merged_mapping(effective_layer)

          send_message(
            t: "mapping",
            device: device[:native_name] || device[:name],
            layer: JSON.generate(@current_layer),
            entries: @layer_manager.normalize_mapping(mapping)
          )
        end

        def send_message(payload)
          @writer.puts(JSON.generate(payload))
          @writer.flush
        end
      end
    end
  end
end
