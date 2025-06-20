# frozen_string_literal: true

module Agents
  module Providers
    # Registry for managing LLM providers
    class Registry
      @providers = {}

      class << self
        # Register a provider
        def register(name, provider_class)
          @providers[name.to_sym] = provider_class
        end

        # Get a provider instance
        def get(name, config = {})
          provider_class = @providers[name.to_sym]
          unless provider_class
            raise ProviderError, "Unknown provider: #{name}. Available: #{@providers.keys.join(', ')}"
          end

          provider_class.new(config)
        end

        # List available providers
        def available
          @providers.keys
        end
      end

      # Register built-in providers
      register :openai, OpenAI
      register :anthropic, Anthropic
    end
  end
end