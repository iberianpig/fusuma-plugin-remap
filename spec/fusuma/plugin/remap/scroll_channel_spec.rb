# frozen_string_literal: true

require "spec_helper"
require "fusuma/plugin/remap/scroll_channel"

RSpec.describe Fusuma::Plugin::Remap::ScrollChannel do
  def build_channel
    described_class.__send__(:new)
  end

  describe "#send_scroll and #receive" do
    it "sends true and false as JSON lines" do
      channel = build_channel

      channel.send_scroll(true)
      channel.send_scroll(false)

      expect(channel.receive).to be true
      expect(channel.receive).to be false
    end

    it "deduplicates unchanged states" do
      channel = build_channel

      channel.send_scroll(true)
      channel.send_scroll(true)
      channel.send_scroll(false)

      expect(channel.receive).to be true
      expect(channel.receive).to be false
    end

    it "returns nil when the reader reaches EOF" do
      channel = build_channel
      channel.writer.close

      expect(channel.receive).to be_nil
    end

    it "returns without blocking or raising when the pipe is full and unread" do
      channel = build_channel
      fill_pipe(channel.writer)

      thread = Thread.new { channel.send_scroll(true) }

      expect(thread.join(0.2)).to eq(thread)
    ensure
      thread&.kill
      thread&.join
    end
  end

  def fill_pipe(writer)
    loop do
      writer.write_nonblock("x" * 4096)
    end
  rescue IO::WaitWritable, Errno::EAGAIN
    nil
  end
end
