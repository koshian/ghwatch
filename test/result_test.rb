# frozen_string_literal: true

require_relative "test_helper"

class ResultTest < Minitest::Test
  def test_parses_last_marked_result
    output = <<~TEXT
      diagnostics
      GHWATCH_RESULT_BEGIN
      {"status":"continue"}
      GHWATCH_RESULT_END
      more diagnostics
      GHWATCH_RESULT_BEGIN
      {"status":"done"}
      GHWATCH_RESULT_END
    TEXT

    assert_equal "done", Ghwatch::Result.parse(output).fetch("status")
  end

  def test_requires_protocol_markers
    assert_raises(Ghwatch::Result::ProtocolError) { Ghwatch::Result.parse("I am done") }
  end
end
