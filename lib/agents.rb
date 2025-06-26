# frozen_string_literal: true

# Main entry point for the Ruby AI Agents SDK
# This file sets up the core Agents module namespace and provides global configuration
# for the multi-agent system including LLM provider setup, API keys, and system defaults.
# It serves as the central configuration hub that other components depend on.

require "ruby_llm"
require_relative "agents/version"

module Agents
  class Error < StandardError; end

  # OpenAI's recommended system prompt prefix for multi-agent workflows
  # This helps agents understand they're part of a coordinated system
  RECOMMENDED_HANDOFF_PROMPT_PREFIX = (
    "# System context\n" \
    "You are part of a multi-agent system called the Ruby Agents SDK, designed to make agent " \
    "coordination and execution easy. Agents uses two primary abstraction: **Agents** and " \
    "**Handoffs**. An agent encompasses instructions and tools and can hand off a " \
    "conversation to another agent when appropriate. " \
    "Handoffs are achieved by calling a handoff function, generally named " \
    "`handoff_to_<agent_name>`. Transfers between agents are handled seamlessly in the background; " \
    "do not mention or draw attention to these transfers in your conversation with the user.\n"
  ).freeze

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

  class Configuration
    attr_accessor :openai_api_key, :anthropic_api_key, :gemini_api_key, :request_timeout, :default_model, :debug

    def initialize
      @default_model = "gpt-4o-mini"
      @request_timeout = 120
      @debug = false
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

# Execution components
require_relative "agents/chat"
require_relative "agents/tool_wrapper"
require_relative "agents/runner"
