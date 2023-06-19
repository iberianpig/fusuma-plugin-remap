# Fusuma::Plugin::Remap [![Gem Version](https://badge.fury.io/rb/fusuma-plugin-remap.svg)](https://badge.fury.io/rb/fusuma-plugin-remap) [![Build Status](https://github.com/iberianpig/fusuma-plugin-remap/actions/workflows/main.yml/badge.svg)](https://github.com/iberianpig/fusuma-plugin-remap/actions/workflows/main.yml)

## Installation

**THIS PLUGIN IS EXPERIMENTAL.**

A Fusuma plugin for remapping keyboard events into virtual input devices. Compatible with other Fusuma plugins.

This plugin empowers users to manipulate keyboard events and convert them into virtual input devices. It is designed to integrate seamlessly with other Fusuma plugins, thus enabling users to construct sophisticated input configurations and achieve distinctive functionalities. A key feature is the dynamic alteration of remapping layers within the Fusuma process, thereby enabling users to adapt their keyboard inputs to suit specific tasks or applications.

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

### Set plugin properties

Open `~/.config/fusuma/config.yml` and add the following code at the bottom in primary context(first section separated by `---`).

```yaml
plugin:
  inputs:
    remap_keyboard_input:
      keyboard_name_patterns: xremap # (optional) specifiy other source keyboard name
  buffers:
    keypress_buffer:
      source: remap_keyboard_input # (required) use buffer of fusuma-plugin-keypress
  executors:
    sendkey_executor:
      device_name: fusuma_virtual_keyboard # (optional) when you use fusuma-plugin-sendkey

---

```

## Properties

### Remap

Currently, remapping is only possible in the thumbsense context.
Please install [fusuma-plugin-thumbsense](https://github.com/iberianpig/fusuma-plugin-thumbsense)

First, add the 'thumbsense' context to `~/.config/fusuma/config.yml`.
The context is separated by `---` and specified by `context: { thumbsense: true }`.

### Example

Set the following code in `~/.config/fusuma/config.yml`.

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

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/iberianpig/fusuma-plugin-remap. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [Contributor Covenant](http://contributor-covenant.org) code of conduct.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the Fusuma::Plugin::Remap project’s codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/iberianpig/fusuma-plugin-remap/blob/master/CODE_OF_CONDUCT.md).
