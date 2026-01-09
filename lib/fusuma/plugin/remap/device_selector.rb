# frozen_string_literal: true

require "revdev"
require "fusuma/device"

module Fusuma
  module Plugin
    module Remap
      # Common device selector for touchpad and keyboard detection
      # Unifies TouchpadSelector implementations across the codebase
      class DeviceSelector
        POLL_INTERVAL = 3 # seconds

        # @param name_patterns [Array, String, nil] patterns for device names
        # @param device_type [Symbol] :touchpad or :keyboard (for logging)
        def initialize(name_patterns: nil, device_type: :touchpad)
          @name_patterns = name_patterns
          @device_type = device_type
          @displayed_waiting = false
        end

        # Select devices that match the name patterns
        # @param wait [Boolean] if true, wait until device is found (polling loop)
        # @return [Array<Revdev::EventDevice>]
        def select(wait: false)
          loop do
            Fusuma::Device.reset # reset cache to get the latest device information
            devices = find_devices
            return to_event_devices(devices) unless devices.empty?
            return [] unless wait

            log_waiting_message unless @displayed_waiting
            sleep POLL_INTERVAL
          end
        end

        private

        def find_devices
          if @name_patterns
            Fusuma::Device.all.select { |d|
              Array(@name_patterns).any? { |name| d.name =~ /#{name}/ }
            }
          else
            # available returns only touchpad devices
            Fusuma::Device.available
          end
        end

        def to_event_devices(devices)
          devices.map { |d| Revdev::EventDevice.new("/dev/input/#{d.id}") }
        end

        def log_waiting_message
          MultiLogger.warn "No #{@device_type} found: #{@name_patterns || "(default patterns)"}"
          MultiLogger.warn "Waiting for #{@device_type} to be connected..."
          @displayed_waiting = true
        end
      end
    end
  end
end
