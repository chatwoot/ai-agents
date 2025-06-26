# frozen_string_literal: true

# Main entry point for the Ruby AI Agents SDK
# This file sets up the core Agents module namespace and provides global configuration
# for the multi-agent system including LLM provider setup, API keys, and system defaults.
# It serves as the central configuration hub that other components depend on.

require "ruby_llm"
require_relative "agents/version"

module Agents
  class Error < StandardError; end

  class << self
    # Logger for debugging (can be set by users)
    attr_accessor :logger

    # Configure both Agents and RubyLLM in one block
    def configure
      yield(configuration) if block_given?
      configure_ruby_llm!
      configuration
    end

    def configuration
      @configuration ||= Configuration.new
    end

    private

    def configure_ruby_llm!
      RubyLLM.configure do |config|
        config.openai_api_key = configuration.openai_api_key if configuration.openai_api_key
        config.anthropic_api_key = configuration.anthropic_api_key if configuration.anthropic_api_key
        config.gemini_api_key = configuration.gemini_api_key if configuration.gemini_api_key
        config.default_model = configuration.default_model
        config.log_level = configuration.debug == true ? :debug : :info
        config.request_timeout = configuration.request_timeout if configuration.request_timeout
      end
    end
  end

  # Configuration for tracing and observability features
  # Provides OpenTelemetry-compatible tracing with flexible export options
  class TracingConfiguration
    attr_accessor :enabled, :export_path, :include_sensitive_data, :otel_format, 
                  :service_name, :jaeger_endpoint, :console_output

    def initialize
      @enabled = false
      @export_path = "./traces"
      @include_sensitive_data = false
      @otel_format = true
      @service_name = "agents-sdk"
      @jaeger_endpoint = ENV["JAEGER_ENDPOINT"] || "http://localhost:14268/api/traces"
      @console_output = false
      
      # Apply environment variable overrides
      apply_env_overrides!
    end

    private

    def apply_env_overrides!
      @export_path = ENV["AGENTS_EXPORT_PATH"] if ENV["AGENTS_EXPORT_PATH"]
      @include_sensitive_data = ENV["AGENTS_INCLUDE_SENSITIVE_DATA"] == "true"
      @service_name = ENV["AGENTS_SERVICE_NAME"] if ENV["AGENTS_SERVICE_NAME"]
      @console_output = ENV["AGENTS_CONSOLE_OUTPUT"] == "true"
    end
  end

  class Configuration
    attr_accessor :openai_api_key, :anthropic_api_key, :gemini_api_key, :request_timeout, :default_model, :debug
    attr_reader :tracing

    def initialize
      @default_model = "gpt-4o-mini"
      @request_timeout = 120
      @debug = false
      @tracing = TracingConfiguration.new
      
      # Check environment variable on initialization
      enable_tracing! if ENV["AGENTS_ENABLE_TRACING"] == "true"
    end

    # Enable tracing with sensible defaults
    # This is the main toggle method for simple tracing activation
    def enable_tracing!
      @tracing.enabled = true
    end

    # Check if at least one provider is configured
    # @return [Boolean] True if any provider has an API key
    def configured?
      @openai_api_key || @anthropic_api_key || @gemini_api_key
    end
  end
end

# Core components
require_relative "agents/result"
require_relative "agents/run_context"
require_relative "agents/tool_context"
require_relative "agents/tool"
require_relative "agents/handoff"
require_relative "agents/agent"
require_relative "agents/tracing"

# Execution components
require_relative "agents/tool_wrapper"
require_relative "agents/runner"

# MCP integration (optional)
require_relative "agents/mcp"
