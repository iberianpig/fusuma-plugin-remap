# frozen_string_literal: true

class MapEntry
  attr_reader :kind, :to

  def initialize(kind, to)
    @kind = kind
    @to = to
  end
end

class InputEvent
  attr_reader :type, :code, :value

  def initialize(type, code, value)
    @type = type
    @code = code
    @value = value
  end
end

class RemapResult
  attr_reader :events, :lines

  def initialize(events, lines)
    @events = events
    @lines = lines
  end
end
