# frozen_string_literal: true

module Agents
  # Configuration class for the Agents SDK
  class Configuration
    # Provider API keys
    attr_accessor :openai_api_key, :anthropic_api_key, :gemini_api_key

    # Provider-specific settings
    attr_accessor :openai_organization, :openai_project, :openai_base_url
    attr_accessor :anthropic_version

    # Request settings
    attr_accessor :request_timeout, :max_turns

    # Core configuration
    attr_accessor :default_provider, :default_model, :debug

    # Initialize with sensible defaults
    def initialize
      # Core defaults
      @default_provider = :openai
      @default_model = "gpt-4o-mini"
      @debug = false
      @max_turns = 10

      # API keys from environment
      @openai_api_key = ENV.fetch("OPENAI_API_KEY", nil)
      @anthropic_api_key = ENV.fetch("ANTHROPIC_API_KEY", nil)
      @gemini_api_key = ENV.fetch("GEMINI_API_KEY", nil)

      # Provider-specific defaults
      @openai_organization = ENV.fetch("OPENAI_ORGANIZATION", nil)
      @openai_project = ENV.fetch("OPENAI_PROJECT", nil)
      @anthropic_version = "2023-06-01"

      # Request settings
      @request_timeout = 120
    end

    # Check if at least one provider is configured
    # @return [Boolean] True if any provider has an API key
    def configured?
      @openai_api_key || @anthropic_api_key || @gemini_api_key
    end

    # Get available providers based on configured API keys
    # @return [Array<Symbol>] Available providers
    def available_providers
      providers = []
      providers << :openai if @openai_api_key
      providers << :anthropic if @anthropic_api_key
      providers << :gemini if @gemini_api_key
      providers
    end

    # Get a provider instance
    # @param name [Symbol] Provider name
    # @return [Providers::Base] Provider instance
    def get_provider(name = nil)
      provider_name = name || @default_provider
      Providers::Registry.get(provider_name, provider_config_for(provider_name))
    end

    # Get provider configuration for a specific provider
    # @param name [Symbol] Provider name
    # @return [Hash] Provider configuration
    def provider_config_for(name)
      case name.to_sym
      when :openai
        {
          api_key: @openai_api_key,
          organization: @openai_organization,
          project: @openai_project,
          base_url: @openai_base_url,
          timeout: @request_timeout
        }.compact
      when :anthropic
        {
          api_key: @anthropic_api_key,
          version: @anthropic_version,
          timeout: @request_timeout
        }.compact
      when :gemini
        {
          api_key: @gemini_api_key,
          timeout: @request_timeout
        }.compact
      else
        {}
      end
    end
  end
end