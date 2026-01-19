# Fusuma::Plugin::Remap [![Gem Version](https://badge.fury.io/rb/fusuma-plugin-remap.svg)](https://badge.fury.io/rb/fusuma-plugin-remap) [![Build Status](https://github.com/iberianpig/fusuma-plugin-remap/actions/workflows/main.yml/badge.svg)](https://github.com/iberianpig/fusuma-plugin-remap/actions/workflows/main.yml)

A Fusuma plugin for remapping keyboard events into virtual input devices. Compatible with other Fusuma plugins.

**THIS PLUGIN IS EXPERIMENTAL.**

This plugin empowers users to manipulate keyboard events and convert them into virtual input devices. It is designed to integrate seamlessly with other Fusuma plugins, thus enabling users to construct sophisticated input configurations and achieve distinctive functionalities. A key feature is the dynamic alteration of remapping layers within the Fusuma process, thereby enabling users to adapt their keyboard inputs to suit specific tasks or applications.

## Installation

This plugin requires [fusuma](https://github.com/iberianpig/fusuma#update) 2.0

### Install dependencies

**NOTE: If you have installed ruby by apt, you must install ruby-dev.**
```sh
$ sudo apt-get install libevdev-dev ruby-dev build-essential
```

### Set up udev rules

fusuma-plugin-remap create virtual input device(`fusuma_virtual_keyboard`) by uinput. So you need to set up udev rules.

```sh
$ echo 'KERNEL=="uinput", MODE="0660", GROUP="input", OPTIONS+="static_node=uinput"' | sudo tee /etc/udev/rules.d/60-udev-fusuma-remap.rules
```

Then, reload udev rules.

```sh
$ sudo udevadm control --reload-rules && sudo udevadm trigger
```

### Install fusuma-plugin-remap

```sh
$ sudo gem install fusuma-plugin-remap
```

## Properties

### Remap

You can remap keys in `~/.config/fusuma/config.yml`. The `remap` section defines key remappings.

#### Basic Remap

Simple key-to-key remapping without any context:

```yaml
remap:
  CAPSLOCK: LEFTCTRL
  LEFTALT: LEFTMETA
  LEFTMETA: LEFTALT
```

#### Key Alias for Modifiers

When a simple key remap is defined (e.g., `CAPSLOCK: LEFTCTRL`), the key acts as an **alias** for the target modifier. The modifier state tracks the remapped key, not the physical key.

```yaml
remap:
  CAPSLOCK: LEFTCTRL  # CAPSLOCK acts as LEFTCTRL alias
  LEFTCTRL+LEFTSHIFT+J: LEFTMETA+LEFTCTRL+DOWN  # Combination using the alias
```

With this configuration:
- Physical `CAPSLOCK` is treated as `LEFTCTRL`
- Physical `CAPSLOCK+LEFTSHIFT+J` triggers `LEFTCTRL+LEFTSHIFT+J` combination
- This outputs `LEFTMETA+LEFTCTRL+DOWN`

#### Output Sequence

You can send multiple key combinations in sequence using an array:

```yaml
remap:
  LEFTCTRL+U: [LEFTSHIFT+HOME, DELETE]  # Select to line start, then delete
  LEFTCTRL+K: [LEFTSHIFT+END, DELETE]   # Select to line end, then delete
```

#### Modifier + Key Combinations

Remap modifier key combinations to other keys or combinations:

```yaml
remap:
  LEFTCTRL+J: DOWN
  LEFTCTRL+K: UP
  LEFTCTRL+H: LEFT
  LEFTCTRL+L: RIGHT
  LEFTALT+N: LEFTCTRL+TAB           # Next tab
  LEFTALT+P: LEFTCTRL+LEFTSHIFT+TAB # Previous tab
```

### Context

You can define different remappings for different contexts. Contexts are separated by `---`.

#### Application Context

Remap keys only for specific applications:

```yaml
---
context:
  application: Alacritty

remap:
  LEFTMETA+N: LEFTCTRL+LEFTSHIFT+T  # New tab in terminal
  LEFTMETA+W: LEFTCTRL+LEFTSHIFT+W  # Close tab
```

#### Thumbsense Context

For thumbsense mode, install [fusuma-plugin-thumbsense](https://github.com/iberianpig/fusuma-plugin-thumbsense):

```yaml
---
context:
  thumbsense: true

remap:
  J: BTN_LEFT
  K: BTN_RIGHT
  F: BTN_LEFT
  D: BTN_RIGHT
  SPACE: BTN_LEFT
```

#### Device Context

You can define different remappings for specific keyboard devices. The `device` pattern uses case-insensitive partial matching against the physical device name.

```yaml
---
# HHKB-specific remappings (matches device names containing "HHKB")
context:
  device: HHKB

remap:
  LEFTCTRL: LEFTMETA  # Swap Ctrl to Meta on HHKB

---
# Built-in keyboard remappings (matches "AT Translated Set 2 keyboard")
context:
  device: AT Translated

remap:
  LEFTALT: LEFTCTRL   # Remap Alt to Ctrl on built-in keyboard
```

To find your keyboard's device name, run:
```sh
libinput list-devices
```

#### Combined Contexts

You can combine multiple context conditions. When multiple contexts are active, mappings are merged with priority order: `device` < `thumbsense` < `application`.

```yaml
---
# HHKB + Thumbsense mode
context:
  device: HHKB
  thumbsense: true

remap:
  J: BTN_LEFT
  K: BTN_RIGHT
```

### Complete Example

```yaml
# Default remappings (always active)
remap:
  CAPSLOCK: LEFTCTRL
  LEFTALT: LEFTMETA
  LEFTMETA: LEFTALT
  LEFTCTRL+J: DOWN
  LEFTCTRL+K: UP

---
# Application-specific remappings
context:
  application: Alacritty

remap:
  LEFTMETA+N: LEFTCTRL+LEFTSHIFT+T

---
# Thumbsense mode
context:
  thumbsense: true

remap:
  J: BTN_LEFT
  K: BTN_RIGHT
```

## Emergency Stop Keybind for Virtual Keyboard

This plugin includes a special keybind for emergency stop. Pressing this key combination will ungrab the physical keyboard and terminate the Fusuma process. This feature is particularly useful in situations where the plugin or system becomes unresponsive.

### How to Use
To execute the emergency stop, press the following key combination(default):
- <kbd>RIGHTCTRL</kbd> → <kbd>LEFTCTRL</kbd>

### Configuration Example
You can configure the emergency stop key in your Fusuma configuration file (`~/.config/fusuma/config.yml`) as follows:

```yaml
plugin:
  inputs:
    remap_keyboard_input:
      emergency_ungrab_keys: RIGHTCTRL+LEFTCTRL # <- Set two keys separated by '+' to trigger the emergency stop
```

This configuration allows you to specify which keys will trigger the emergency stop functionality.
It is important to verify this keybind to ensure a swift response during unexpected situations.

### Input Device Detection

#### Keyboard

configure `plugin.inputs.remap_keyboard_input` in `~/.config/fusuma/config.yml` to specify which physical keyboard to remap.

If your external or built-in keyboard is not detected, run `libinput list-devices` to find its name and add a matching pattern under `keyboard_name_patterns`.

```yaml
plugin:
  inputs:
    remap_keyboard_input:
      # By default, Fusuma will detect physical keyboards matching these patterns.
      # You can specify multiple regular‐expression strings in an array.
      keyboard_name_patterns:
        # Default value
        - keyboard|Keyboard|KEYBOARD

      # Emergency stop key combination.
      # Specify exactly two keys joined by '+'.
      emergency_ungrab_keys: RIGHTCTRL+LEFTCTRL
```

You can customize `keyboard_name_patterns` like this:

```yaml
plugin:
  inputs:
    remap_keyboard_input:
      keyboard_name_patterns:
        - xremap                     # Virtual keyboard created by another remapper
        - PFU Limited HHKB-Hybrid    # External keyboard
        - keyboard|Keyboard|KEYBOARD # Default pattern
```

If your keyboard isn’t detected, run:

```sh
libinput list-devices
```

and add a suitable name pattern.

#### Touchpad

To specify touchpad name, configure `plugin.inputs.remap_touchpad_input`:

```yaml
plugin:
  inputs:
    remap_touchpad_input:
      # By default, Fusuma will detect physical touchpads matching these patterns.
      touchpad_name_patterns:
        # Default values
        - touchpad|Touchpad|TOUCHPAD
        - trackpad|Trackpad|TRACKPAD
```

You can customize `touchpad_name_patterns` like this:

```yaml
plugin:
  inputs:
    remap_touchpad_input:
      touchpad_name_patterns:
        - Apple Inc. Magic Trackpad   # External Trackpad
        - your touchpad device name   # Any other touchpad
        - Touchpad|Trackpad           # match to "Touchpad" or "Trackpad"
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/iberianpig/fusuma-plugin-remap. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [Contributor Covenant](http://contributor-covenant.org) code of conduct.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the Fusuma::Plugin::Remap project’s codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/iberianpig/fusuma-plugin-remap/blob/master/CODE_OF_CONDUCT.md).
