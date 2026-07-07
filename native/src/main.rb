# frozen_string_literal: true

require_relative "constants"
require_relative "event_loop"
require_relative "ffi"

SHIM.shim_setup

puts "{\"t\":\"hello\",\"app\":" + JsonWriter.quote(Const::APP_NAME) +
  ",\"version\":" + JsonWriter.quote(Const::APP_VERSION) + "}"
SHIM.shim_flush

EventLoop.new.run
