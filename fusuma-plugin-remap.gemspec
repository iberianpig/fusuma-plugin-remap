# frozen_string_literal: true

lib = File.expand_path("lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "fusuma/plugin/remap/version"

Gem::Specification.new do |spec|
  spec.name = "fusuma-plugin-remap"
  spec.version = Fusuma::Plugin::Remap::VERSION
  spec.authors = ["iberianpig"]
  spec.email = ["yhkyky@gmail.com"]

  spec.summary = "A Fusuma plugin for remapping keyboard events into virtual input devices."
  spec.description = "This plugin empowers users to manipulate keyboard events and convert them into virtual input devices. It is designed to integrate seamlessly with other Fusuma plugins, thus enabling users to construct sophisticated input configurations and achieve distinctive functionalities. A key feature is the dynamic alteration of remapping layers within the Fusuma process, thereby enabling users to adapt their keyboard inputs to suit specific tasks or applications."
  spec.homepage = "https://github.com/iberianpig/fusuma-plugin-remap"
  spec.license = "MIT"

  spec.files = Dir["{bin,lib,exe}/**/*", "LICENSE*", "README*", "*.gemspec"]
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.required_ruby_version = ">= 2.7"
  # https://packages.ubuntu.com/search?keywords=ruby&searchon=names&exact=1&suite=all&section=main
  # support focal (20.04LTS) 2.7

  spec.add_dependency "fusuma", ">= 3.11.0"
  spec.add_dependency "fusuma-plugin-keypress", ">= 0.11.0"
  spec.add_dependency "fusuma-plugin-sendkey", ">= 0.12.0"
  spec.add_dependency "msgpack"
  spec.add_dependency "revdev"
  spec.add_dependency "ruinput"
  spec.metadata = {
    "rubygems_mfa_required" => "true"
  }
end
