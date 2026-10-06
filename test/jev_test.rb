# frozen_string_literal: true

require_relative "test_helper"
require "socket"

class JevTest < Minitest::Test
  def serve(status, body)
    server = TCPServer.new("127.0.0.1", 0)
    received = {}
    thread = Thread.new do
      client = server.accept
      head = +""
      head << client.gets until head.end_with?("\r\n\r\n")
      received[:head] = head
      received[:body] = client.read(head[/Content-Length: (\d+)/i, 1].to_i)
      client.write("HTTP/1.1 #{status}\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
      client.close
    end
    [server.addr[1], received, thread, server]
  end

  def test_posts_state_and_questions_with_the_key_and_reads_answers
    answer = {"model" => "jev-1.13.0", "answers" => {"status" => {"type" => "choice", "choice" => "deferred", "confidence" => 0.9}}}
    port, received, thread, server = serve("200 OK", JSON.generate(answer))
    jev = Ghwatch::Jev.new(url: "http://127.0.0.1:#{port}/v1/systemone", api_key: "secret", model: "jev-latest", timeout: 5)
    response = jev.evaluate(state: {"issue" => {"number" => 1}}, questions: {"status" => {"type" => "choice"}})
    thread.join
    assert_equal "deferred", response.dig("answers", "status", "choice")
    assert_match(%r{\APOST /v1/systemone }, received[:head])
    assert_includes received[:head], "Authorization: Bearer secret"
    assert_equal({"state" => {"issue" => {"number" => 1}}, "model" => "jev-latest", "questions" => {"status" => {"type" => "choice"}}},
      JSON.parse(received[:body]))
  ensure
    server&.close
  end

  def test_http_errors_raise
    port, _received, thread, server = serve("529 Overloaded", "{}")
    jev = Ghwatch::Jev.new(url: "http://127.0.0.1:#{port}/v1/systemone", api_key: "k", model: "jev-latest", timeout: 5)
    error = assert_raises(Ghwatch::Jev::Error) { jev.evaluate(state: "s", questions: {}) }
    thread.join
    assert_match(/HTTP 529/, error.message)
  ensure
    server&.close
  end
end
