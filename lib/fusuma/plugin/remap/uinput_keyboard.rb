require "ruinput"

class UinputKeyboard < Ruinput::UinputDevice
  include Ruinput

  # create virtual event divece
  # _name_ :: device name
  # _id_ :: InputId ("struct input_id" on input.h)
  def create name = DEFAULT_DEVICE_NAME, id = DEFAULT_INPUT_ID
    if !name.is_a? String
      raise ArgumentError, "1st arg expect String"
    elsif !id.is_a? Revdev::InputId
      raise ArgumentError, "2nd arg expect Revdev::InputId"
    end

    uud = Ruinput::UinputUserDev.new({
      name: name,
      id: id,
      ff_effects_max: 0,
      absmax: [],
      absmin: [],
      absfuzz: [],
      absflat: []
    })

    @file.syswrite uud.to_byte_string

    set_all_events

    @file.ioctl UI_DEV_CREATE, nil
    @is_created = true
  end

  def set_all_events
    raise "invalid method call: this uinput is already created" if @is_created

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
      Revdev::BTN_RIGHT,
      Revdev::BTN_SIDE,
      Revdev::BTN_EXTRA,
      Revdev::BTN_FORWARD,
      Revdev::BTN_BACK,
      Revdev::BTN_TASK
      # Revdev::BTN_TRIGGER, # libinput recognized as joystick if set
    ].freeze

    keyboard_keys = Revdev.constants.select { |c| c.start_with? "KEY_" }.map { |c| Revdev.const_get(c) }.freeze

    @file.ioctl UI_SET_EVBIT, Revdev::EV_KEY
    @counter = 0
    Revdev::KEY_CNT.times do |i|
      # https://github.com/mooz/xkeysnail/pull/101/files
      if keyboard_keys.include?(i) || mouse_btns.include?(i)
        # puts "setting #{i} (#{Revdev::REVERSE_MAPS[:KEY][i]})"
        @file.ioctl UI_SET_KEYBIT, i
      end
    end

    # @file.ioctl UI_SET_EVBIT, Revdev::EV_MSC
    # Revdev::MSC_CNT.times do |i|
    #   @file.ioctl UI_SET_MSCBIT, i
    # end

    mouse_rel = [
      Revdev::REL_X,
      Revdev::REL_Y,
      Revdev::REL_WHEEL,
      Revdev::REL_HWHEEL
    ].freeze

    @file.ioctl UI_SET_EVBIT, Revdev::EV_REL
    Revdev::REL_CNT.times do |i|
      if mouse_rel.include?(i)
        # puts "setting #{i} (#{Revdev::REVERSE_MAPS[:REL][i]})"
        @file.ioctl UI_SET_RELBIT, i
      end
    end

    @file.ioctl UI_SET_EVBIT, Revdev::EV_REP
  end
end
