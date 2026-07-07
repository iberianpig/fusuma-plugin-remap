# frozen_string_literal: true

module Const
  APP_NAME = "fusuma-remap-keyboard"
  APP_VERSION = "0.1.0"
  VIRTUAL_KEYBOARD_NAME = "fusuma_virtual_keyboard"

  EV_SYN = 0
  EV_KEY = 1
  EV_REL = 2
  EV_REP = 20

  SYN_REPORT = 0

  REL_X = 0
  REL_Y = 1
  REL_WHEEL = 8
  REL_HWHEEL = 6

  ENOBUFS_NEG = -105

  BUS_VIRTUAL = 6
  BUS_I8042 = 17

  DEFAULT_VENDOR = 1
  DEFAULT_PRODUCT = 1
  DEFAULT_VERSION = 1

  DEFAULT_EMERGENCY_KEYS = ["RIGHTCTRL", "LEFTCTRL"]
end
