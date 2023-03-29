require 'ruinput'

class RuinputDevicePatched < Ruinput::UinputDevice
  include Ruinput
  def set_all_events
    raise 'invalid method call: this uinput is already created' if @is_created

    mouse_btns = [
      Revdev::BTN_0,
      Revdev::BTN_MISC,
      Revdev::BTN_1,
      Revdev::BTN_2,
      Revdev::BTN_3,
      Revdev::BTN_4,
      Revdev::BTN_5,
      Revdev::BTN_6,
      Revdev::BTN_7,
      Revdev::BTN_8,
      Revdev::BTN_9,
      Revdev::BTN_LEFT,
      Revdev::BTN_MOUSE,
      Revdev::BTN_MIDDLE,
      Revdev::BTN_RIGHT
    ].freeze

    keyboard_keys = Revdev.constants.select { |c| c.start_with? 'KEY_' }.map { |c| Revdev.const_get(c) }.freeze

    @file.ioctl UI_SET_EVBIT, Revdev::EV_KEY
    (Revdev::KEY_RESERVED...Revdev::KEY_CNT).each do |n|
      # https://github.com/mooz/xkeysnail/pull/101/files
      next unless keyboard_keys.include?(n) || mouse_btns.include?(n)

      @file.ioctl UI_SET_KEYBIT, n
    end

    # @file.ioctl UI_SET_EVBIT, Revdev::EV_MSC
    # Revdev::MSC_CNT.times do |i|
    #   @file.ioctl UI_SET_MSCBIT, i
    # end

    # kernel bug: device has min == max on ABS_Y 
    # @file.ioctl UI_SET_EVBIT, Revdev::EV_ABS
    # Revdev::ABS_CNT.times do |i|
    #   @file.ioctl UI_SET_ABSBIT, i
    # end

    @file.ioctl UI_SET_EVBIT, Revdev::EV_REP
  end
end
