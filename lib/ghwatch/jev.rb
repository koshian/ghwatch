# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Ghwatch
  # Minimal client for TypeSafe's System One API (POST /v1/systemone):
  # a state plus typed questions in, typed answers with confidence out.
  class Jev
    class Error < StandardError; end

    def initialize(url:, api_key:, model:, timeout: 60)
      @uri = URI(url)
      @api_key = api_key
      @model = model
      @timeout = timeout
    end

    def evaluate(state:, questions:)
      request = Net::HTTP::Post.new(@uri)
      request["Authorization"] = "Bearer #{@api_key}"
      request["Content-Type"] = "application/json"
      request.body = JSON.generate({"state" => state, "model" => @model, "questions" => questions})

      response = Net::HTTP.start(@uri.host, @uri.port, use_ssl: @uri.scheme == "https",
        open_timeout: @timeout, read_timeout: @timeout) { |http| http.request(request) }
      raise Error, "HTTP #{response.code}: #{response.body.to_s[0, 300]}" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    rescue JSON::ParserError, SystemCallError, IOError, Timeout::Error, OpenSSL::SSL::SSLError => e
      raise Error, "#{e.class}: #{e.message}"
    end
  end
end
