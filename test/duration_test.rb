# frozen_string_literal: true

require_relative "test_helper"

class DurationTest < Minitest::Test
  def test_parses_human_durations
    assert_equal 10, Ghwatch::Duration.seconds("10s")
    assert_equal 600, Ghwatch::Duration.seconds("10m")
    assert_equal 7200, Ghwatch::Duration.seconds("2h")
    assert_equal 86_400, Ghwatch::Duration.seconds("1d")
  end

  def test_rejects_invalid_duration
    assert_raises(ArgumentError) { Ghwatch::Duration.seconds("soon") }
  end
end
