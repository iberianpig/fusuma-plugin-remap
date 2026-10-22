# frozen_string_literal: true

require_relative "constants"
require_relative "ffi"
require_relative "keycodes"

class UinputKeyboard
  ALLOWED_BUTTONS = {
    "BTN_0" => 1,
    "BTN_MISC" => 1,
    "BTN_1" => 1,
    "BTN_2" => 1,
    "BTN_3" => 1,
    "BTN_4" => 1,
    "BTN_5" => 1,
    "BTN_6" => 1,
    "BTN_7" => 1,
    "BTN_8" => 1,
    "BTN_9" => 1,
    "BTN_LEFT" => 1,
    "BTN_MOUSE" => 1,
    "BTN_MIDDLE" => 1,
    "BTN_RIGHT" => 1,
    "BTN_SIDE" => 1,
    "BTN_EXTRA" => 1,
    "BTN_FORWARD" => 1,
    "BTN_BACK" => 1,
    "BTN_TASK" => 1
  }.freeze

  attr_reader :fd

  def initialize
    @fd = -1
    @created = false
  end

  def create(name, bustype, vendor, product, version)
    @fd = SHIM.shim_open_uinput
    raise "open /dev/uinput failed: " + @fd.to_s if @fd < 0

    must(SHIM.shim_ui_set_evbit(@fd, Const::EV_KEY), "UI_SET_EVBIT EV_KEY")
    Keycodes::KEY_CODES.each do |code|
      next unless enabled_key_code?(code)

      must(SHIM.shim_ui_set_keybit(@fd, code), "UI_SET_KEYBIT " + code.to_s)
    end

    must(SHIM.shim_ui_set_evbit(@fd, Const::EV_REL), "UI_SET_EVBIT EV_REL")
    must(SHIM.shim_ui_set_relbit(@fd, Const::REL_X), "UI_SET_RELBIT REL_X")
    must(SHIM.shim_ui_set_relbit(@fd, Const::REL_Y), "UI_SET_RELBIT REL_Y")
    must(SHIM.shim_ui_set_relbit(@fd, Const::REL_WHEEL), "UI_SET_RELBIT REL_WHEEL")
    must(SHIM.shim_ui_set_relbit(@fd, Const::REL_HWHEEL), "UI_SET_RELBIT REL_HWHEEL")

    must(SHIM.shim_ui_set_evbit(@fd, Const::EV_REP), "UI_SET_EVBIT EV_REP")
    must(SHIM.shim_ui_dev_setup(@fd, name, bustype, vendor, product, version), "UI_DEV_SETUP")
    must(SHIM.shim_ui_dev_create(@fd), "UI_DEV_CREATE")
    @created = true
  end

  def emit(type, code, value)
    return -1 if @fd < 0

    SHIM.shim_emit(@fd, type, code, value)
  end

  def destroy
    if @fd >= 0
      SHIM.shim_ui_dev_destroy(@fd) if @created
      SHIM.shim_close(@fd)
    end
    @fd = -1
    @created = false
  end

  private

  def must(rc, label)
    raise label + " failed: " + rc.to_s if rc < 0
  end

  def enabled_key_code?(code)
    name = Keycodes::KEYMAP[code]
    return false if name.nil?
    return true unless name.start_with?("BTN_")

    ALLOWED_BUTTONS[name] == 1
  end
end
