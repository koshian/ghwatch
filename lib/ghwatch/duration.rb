# frozen_string_literal: true

module Ghwatch
  module Duration
    UNITS = {
      "s" => 1,
      "m" => 60,
      "h" => 60 * 60,
      "d" => 24 * 60 * 60
    }.freeze

    module_function

    def seconds(value)
      return value if value.is_a?(Numeric)

      text = value.to_s.strip
      match = /\A(\d+(?:\.\d+)?)([smhd])\z/.match(text)
      raise ArgumentError, "invalid duration: #{value.inspect}" unless match

      (match[1].to_f * UNITS.fetch(match[2])).to_i
    end
  end
end
