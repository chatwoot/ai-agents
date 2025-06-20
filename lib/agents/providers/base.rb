# frozen_string_literal: true

require "faraday"
require "faraday/retry"
require "json"

module Agents
  module Providers
    # Base provider class for LLM integration
    class Base
      def initialize(config = {})
        @config = config
        @client = build_client
      end

      # Make a chat request
      def chat(messages, model:, tools: nil, **options)
        raise NotImplementedError, "Subclasses must implement #chat"
      end

      private

      def build_client
        Faraday.new do |builder|
          builder.request :json
          builder.request :retry
          builder.response :json
          builder.adapter Faraday.default_adapter
        end
      end
    end
  end
end