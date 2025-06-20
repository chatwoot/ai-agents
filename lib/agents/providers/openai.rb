# frozen_string_literal: true

module Agents
  module Providers
    # OpenAI provider for GPT models
    class OpenAI < Base
      API_URL = "https://api.openai.com/v1/chat/completions"

      def initialize(config = {})
        super
        @api_key = config[:api_key] || raise(ProviderError, "OpenAI API key required")
        @base_url = config[:base_url] || API_URL
      end

      def chat(messages, model:, tools: nil, **options)
        request_body = {
          model: model,
          messages: messages
        }

        request_body[:tools] = tools if tools && !tools.empty?
        request_body.merge!(options.except(:provider))

        response = @client.post(@base_url) do |req|
          req.headers["Authorization"] = "Bearer #{@api_key}"
          req.headers["Content-Type"] = "application/json"
          req.body = request_body
        end

        handle_response(response)
      rescue Faraday::Error => e
        raise ProviderError, "OpenAI request failed: #{e.message}"
      end

      private

      def handle_response(response)
        unless response.success?
          raise ProviderError, "OpenAI API error: #{response.status} - #{response.body}"
        end

        data = response.body
        choice = data.dig("choices", 0)

        unless choice
          raise ProviderError, "No choices returned from OpenAI"
        end

        {
          content: choice.dig("message", "content"),
          tool_calls: choice.dig("message", "tool_calls"),
          finish_reason: choice["finish_reason"],
          usage: data["usage"]
        }
      end
    end
  end
end