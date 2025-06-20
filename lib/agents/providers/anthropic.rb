# frozen_string_literal: true

module Agents
  module Providers
    # Anthropic provider for Claude models
    class Anthropic < Base
      API_URL = "https://api.anthropic.com/v1/messages"

      def initialize(config = {})
        super
        @api_key = config[:api_key] || raise(ProviderError, "Anthropic API key required")
        @version = config[:version] || "2023-06-01"
      end

      def chat(messages, model:, tools: nil, **options)
        # Convert OpenAI format to Anthropic format
        system_message = messages.find { |m| m[:role] == "system" }
        user_messages = messages.reject { |m| m[:role] == "system" }

        request_body = {
          model: model,
          max_tokens: options[:max_tokens] || 1024,
          messages: user_messages
        }

        request_body[:system] = system_message[:content] if system_message
        request_body[:tools] = convert_tools(tools) if tools && !tools.empty?

        response = @client.post(API_URL) do |req|
          req.headers["x-api-key"] = @api_key
          req.headers["anthropic-version"] = @version
          req.headers["Content-Type"] = "application/json"
          req.body = request_body
        end

        handle_response(response)
      rescue Faraday::Error => e
        raise ProviderError, "Anthropic request failed: #{e.message}"
      end

      private

      def convert_tools(tools)
        tools.map do |tool|
          {
            name: tool.dig(:function, :name),
            description: tool.dig(:function, :description),
            input_schema: tool.dig(:function, :parameters)
          }
        end
      end

      def handle_response(response)
        unless response.success?
          raise ProviderError, "Anthropic API error: #{response.status} - #{response.body}"
        end

        data = response.body
        content_block = data["content"]&.first

        unless content_block
          raise ProviderError, "No content returned from Anthropic"
        end

        {
          content: content_block["text"],
          tool_calls: nil, # Anthropic handles tools differently
          finish_reason: data["stop_reason"],
          usage: data["usage"]
        }
      end
    end
  end
end