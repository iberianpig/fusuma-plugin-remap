# frozen_string_literal: true

lib = File.expand_path('lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'fusuma/plugin/remap/version'

Gem::Specification.new do |spec|
  spec.name = 'fusuma-plugin-remap'
  spec.version = Fusuma::Plugin::Remap::VERSION
  spec.authors = ['iberianpig']
  spec.email = ['yhkyky@gmail.com']

  spec.summary = 'A Fusuma plugin that enables grabbing and controlling devices, remapping keyboard, touchpad, and mouse events, and dynamically changing remapping layers. Designed to integrate seamlessly with other Fusuma plugins for enhanced device customization.'
  spec.description = "This plugin offers the capability to grab and control various input devices, including keyboards, touchpads, and mice. By remapping key events, touchpad gestures, and mouse button events, users can create a highly customized and efficient input experience.

The plugin is designed to integrate seamlessly with other Fusuma plugins, allowing users to build complex input configurations and achieve unique functionalities. One of the key features of this plugin is the ability to dynamically change remapping layers within the Fusuma process, enabling users to adapt their input devices according to specific tasks or applications."
  spec.homepage = 'https://github.com/iberianpig/fusuma-plugin-remap'
  spec.license = 'MIT'

  spec.files = Dir['{bin,lib,exe}/**/*', 'LICENSE*', 'README*', '*.gemspec']
  spec.bindir = 'exe'
  spec.executables = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']

  spec.required_ruby_version = '>= 2.5.1'
  spec.add_dependency 'fusuma', '~> 2.0'
  spec.add_dependency "revdev"
  spec.add_dependency "ruinput"
  spec.metadata = {
    'rubygems_mfa_required' => 'true'
  }
end
