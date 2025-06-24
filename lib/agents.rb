# frozen_string_literal: true

# Main entry point for the Ruby AI Agents SDK
# This file sets up the core Agents module namespace and provides global configuration
# for the multi-agent system including LLM provider setup, API keys, and system defaults.
# It serves as the central configuration hub that other components depend on.

require "ruby_llm"
require_relative "agents/version"

module Agents
  class Error < StandardError; end
end

# require_relative "agents/context"
# require_relative "agents/result"
require_relative "agents/run_context"
require_relative "agents/tool_context"
require_relative "agents/tool"
# require_relative "agents/handoff"
# require_relative "agents/guardrail"
require_relative "agents/agent"
# require_relative "agents/runner"
# require_relative "agents/items"

# module Agents
#   # Recommended prompt prefix for agents that use handoffs
#   RECOMMENDED_HANDOFF_PROMPT_PREFIX = <<~PREFIX.freeze
#     # System context
#     You are part of a multi-agent system called the Agents SDK, designed to make agent coordination and execution easy. Agents uses two primary abstraction: **Agents** and **Handoffs**. An agent encompasses instructions and tools and can hand off a conversation to another agent when appropriate. Handoffs are achieved by calling a handoff function, generally named `transfer_to_<agent_name>`.#{" "}

#     CRITICAL: Transfers between agents are handled seamlessly in the background and are completely invisible to users. NEVER mention transfers, handoffs, or connecting to other agents in your conversation with the user. Simply call the transfer function when needed without any explanation to the user.
#   PREFIX

#   class << self
#     # Configure both Agents and RubyLLM in one block
#     # @yield [Agents::Configuration] Configuration instance
#     # @return [Agents::Configuration] The configuration
#     def configure
#       yield(configuration) if block_given?
#       # Apply RubyLLM configuration after our configuration is set
#       configure_ruby_llm!
#       configuration
#     end

#     # Get the current configuration
#     # @return [Agents::Configuration] The configuration instance
#     def configuration
#       @configuration ||= Configuration.new
#     end

#     # Helper method to add handoff instructions to agent prompts
#     def prompt_with_handoff_instructions(prompt)
#       "#{RECOMMENDED_HANDOFF_PROMPT_PREFIX}\n\n#{prompt}"
#     end

#     private

#     # Configure RubyLLM with our settings
#     def configure_ruby_llm!
#       RubyLLM.configure do |config|
#         # Pass through API keys
#         config.openai_api_key = configuration.openai_api_key if configuration.openai_api_key
#         config.anthropic_api_key = configuration.anthropic_api_key if configuration.anthropic_api_key
#         config.gemini_api_key = configuration.gemini_api_key if configuration.gemini_api_key

#         # Pass through other settings
#         config.default_model = configuration.default_model
#         config.request_timeout = configuration.request_timeout if configuration.request_timeout
#         config.log_level = configuration.debug ? :debug : :info
#       end
#     end
#   end

#   # Configuration class that mirrors RubyLLM's configuration options
#   # plus Agents-specific settings
#   class Configuration
#     # RubyLLM configuration options
#     attr_accessor :openai_api_key, :anthropic_api_key, :gemini_api_key
#     attr_accessor :request_timeout, :retry_attempts, :retry_intervals, :max_turns, :default_timeout

#     # Agents-specific configuration
#     attr_accessor :default_provider, :default_model, :debug

#     # Initialize with sensible defaults
#     def initialize
#       # Agents defaults
#       @default_provider = :openai
#       @default_model = "gpt-4.1-mini"
#       @debug = false
#       @max_turns = 10
#       @default_timeout = 300

#       # RubyLLM defaults
#       @openai_api_key = ENV.fetch("OPENAI_API_KEY", nil)
#       @anthropic_api_key = ENV.fetch("ANTHROPIC_API_KEY", nil)
#       @gemini_api_key = ENV.fetch("GEMINI_API_KEY", nil)
#       @request_timeout = 120
#       @retry_attempts = 3
#     end

#     # Check if at least one provider is configured
#     # @return [Boolean] True if any provider has an API key
#     def configured?
#       @openai_api_key || @anthropic_api_key || @gemini_api_key
#     end

#     # Get available providers based on configured API keys
#     # @return [Array<Symbol>] Available providers
#     def available_providers
#       providers = []
#       providers << :openai if @openai_api_key
#       providers << :anthropic if @anthropic_api_key
#       providers << :gemini if @gemini_api_key
#       providers
#     end
#   end
# end
