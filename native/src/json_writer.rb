# frozen_string_literal: true

# Small hand-written JSON helpers for Spinel builds.
module JsonWriter
  def self.escape(s)
    out = ""
    s.each_char do |c|
      if c == "\""
        out += "\\\""
      elsif c == "\\"
        out += "\\\\"
      elsif c == "\n"
        out += "\\n"
      elsif c == "\t"
        out += "\\t"
      elsif c == "\r"
        out += "\\r"
      else
        out += c
      end
    end
    out
  end

  def self.quote(s)
    "\"" + escape(s) + "\""
  end
end
