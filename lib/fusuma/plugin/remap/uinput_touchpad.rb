require "ruinput"

class UinputTouchpad < Ruinput::UinputDevice
  include Ruinput

  # create from original event device
  # copy absinfo using eviocgabs
  def create_from_device(name:, device:)
    id = Revdev::InputId.new(
      {
        bustype: Revdev::BUS_I8042,
        vendor: device.device_id.vendor,
        product: device.device_id.product,
        version: device.device_id.version
      }
    )

    absinfo = {
      Revdev::ABS_X => device.absinfo_for_axis(Revdev::ABS_X),
      Revdev::ABS_Y => device.absinfo_for_axis(Revdev::ABS_Y),
      Revdev::ABS_MT_POSITION_X => device.absinfo_for_axis(Revdev::ABS_MT_POSITION_X),
      Revdev::ABS_MT_POSITION_Y => device.absinfo_for_axis(Revdev::ABS_MT_POSITION_Y),
      Revdev::ABS_MT_SLOT => device.absinfo_for_axis(Revdev::ABS_MT_SLOT),
      Revdev::ABS_MT_TOOL_TYPE => device.absinfo_for_axis(Revdev::ABS_MT_TOOL_TYPE),
      Revdev::ABS_MT_TRACKING_ID => device.absinfo_for_axis(Revdev::ABS_MT_TRACKING_ID)
    }

    uud = Ruinput::UinputUserDev.new({
      name: name,
      id: id,
      ff_effects_max: 0,
      absmax: Array.new(Revdev::ABS_CNT, 0).tap { |a| absinfo.each { |k, v| a[k] = v[:absmax] } },
      absmin: Array.new(Revdev::ABS_CNT, 0).tap { |a| absinfo.each { |k, v| a[k] = v[:absmin] } },
      absfuzz: Array.new(Revdev::ABS_CNT, 0).tap { |a| absinfo.each { |k, v| a[k] = v[:absfuzz] } },
      absflat: Array.new(Revdev::ABS_CNT, 0).tap { |a| absinfo.each { |k, v| a[k] = v[:absflat] } },
      resolution: Array.new(Revdev::ABS_CNT, 0).tap { |a| absinfo.each { |k, v| a[k] = v[:resolution] } }
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
      # Revdev::BTN_TRIGGER, # disable because libinput recognize this device as a joystick
    ].freeze

    touchpad_btns = [
      Revdev::BTN_TOUCH,
      Revdev::BTN_TOOL_FINGER,
      Revdev::BTN_TOOL_DOUBLETAP,
      Revdev::BTN_TOOL_TRIPLETAP,
      Revdev::BTN_TOOL_QUADTAP,
      0x148 # define BTN_TOOL_QUINTTAP	0x148	/* Five fingers on trackpad */
    ].freeze

    @file.ioctl UI_SET_EVBIT, Revdev::EV_KEY
    @counter = 0
    Revdev::KEY_CNT.times do |i|
      # https://github.com/mooz/xkeysnail/pull/101/files
      if mouse_btns.include?(i) || touchpad_btns.include?(i)
        # puts "setting #{i} (#{Revdev::REVERSE_MAPS[:KEY][i]})"
        @file.ioctl UI_SET_KEYBIT, i
      else
        # puts "skipping #{i} (#{Revdev::REVERSE_MAPS[:KEY][i]})"
      end
    end

    touchpad_abs = [
      Revdev::ABS_X,
      Revdev::ABS_Y,
      # Revdev::ABS_PRESSURE,
      Revdev::ABS_MT_SLOT,
      # Revdev::ABS_MT_TOUCH_MAJOR,
      # Revdev::ABS_MT_TOUCH_MINOR,
      Revdev::ABS_MT_POSITION_X,
      Revdev::ABS_MT_POSITION_Y,
      Revdev::ABS_MT_TRACKING_ID,
      Revdev::ABS_MT_TOOL_TYPE
    ].freeze

    # kernel bug: device has min == max on ABS_Y
    @file.ioctl UI_SET_EVBIT, Revdev::EV_ABS
    Revdev::ABS_CNT.times do |i|
      if touchpad_abs.include?(i)
        puts "setting #{i} (#{Revdev::REVERSE_MAPS[:ABS][i]})"
        @file.ioctl UI_SET_ABSBIT, i
      else
        puts "skipping #{i} (#{Revdev::REVERSE_MAPS[:ABS][i]})"
      end
    end

    touchpad_rels = [
      Revdev::REL_X,
      Revdev::REL_Y,
      Revdev::REL_WHEEL,
      Revdev::REL_HWHEEL
    ].freeze

    @file.ioctl UI_SET_EVBIT, Revdev::EV_REL
    Revdev::REL_CNT.times do |i|
      if touchpad_rels.include?(i)
        puts "setting #{i} (#{Revdev::REVERSE_MAPS[:REL][i]})"
        @file.ioctl UI_SET_RELBIT, i
      else
        puts "skipping #{i} (#{Revdev::REVERSE_MAPS[:REL][i]})"
      end
    end

    @file.ioctl UI_SET_EVBIT, Revdev::EV_REP

    touchpad_mscs = [
      0x05 # define MSC_TIMESTAMP		0x05
    ]
    @file.ioctl UI_SET_EVBIT, Revdev::EV_MSC
    Revdev::MSC_CNT.times do |i|
      if touchpad_mscs.include?(i)
        # puts "setting #{i} (#{Revdev::REVERSE_MAPS[:MSC][i]})"
        @file.ioctl UI_SET_MSCBIT, i
      else
        # puts "skipping #{i} (#{Revdev::REVERSE_MAPS[:MSC][i]})"
      end
    end
  end
end

class Revdev::EventDevice
  def absinfo_for_axis(abs)
    data = read_ioctl_with(eviocgabs(abs))

    {
      value: data[0, 4].unpack1("l<"),
      absmin: data[4, 4].unpack1("l<"),
      absmax: data[8, 4].unpack1("l<"),
      absfuzz: data[12, 4].unpack1("l<"),
      absflat: data[16, 4].unpack1("l<"),
      resolution: data[20, 4].unpack1("l<")
    }
  end

  # FIXME: undefined constants in revdev
  def eviocgabs(abs)
    # #define EVIOCGABS(abs)	_IOR('E', 0x40 + abs, struct input_absinfo)
    0x80404540 + abs # EVIOCGABS(abs)
  end
end
