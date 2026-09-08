# frozen_string_literal: true

# Main entry point for the Ruby AI Agents SDK
# This file sets up the core Agents module namespace and provides global configuration
# for the multi-agent system including LLM provider setup, API keys, and system defaults.
# It serves as the central configuration hub that other components depend on.

require "ruby_llm"
require_relative "agents/version"

# Multi-agent orchestration built on RubyLLM.
module Agents
  class Error < StandardError; end

  # OpenAI's recommended system prompt prefix for multi-agent workflows
  # This helps agents understand they're part of a coordinated system
  RECOMMENDED_HANDOFF_PROMPT_PREFIX =
    "# System context\n" \
    "You are part of a multi-agent system called the Ruby Agents SDK, designed to make agent " \
    "coordination and execution easy. Agents uses two primary abstraction: **Agents** and " \
    "**Handoffs**. An agent encompasses instructions and tools and can hand off a " \
    "conversation to another agent when appropriate. " \
    "Handoffs are achieved by calling a handoff function, generally named " \
    "`handoff_to_<agent_name>`. Transfers between agents are handled seamlessly in the background; " \
    "do not mention or draw attention to these transfers in your conversation with the user.\n"

  class << self
    # Logger for debugging (can be set by users)
    attr_accessor :logger

    # Keep one source of provider settings, including options added by RubyLLM.
    # https://rubyllm.com/configuration/
    def configure(&block)
      RubyLLM.configure(&block) if block
      configuration
    end

    def configuration
      RubyLLM.config
    end
  end
end

# Core components
require_relative "agents/result"
require_relative "agents/run_context"
require_relative "agents/tool_context"
require_relative "agents/tool"
require_relative "agents/handoff"
require_relative "agents/helpers"
require_relative "agents/agent"

# Execution components
require_relative "agents/tool_wrapper"
require_relative "agents/callback_manager"
require_relative "agents/agent_runner"
require_relative "agents/runner"
require_relative "agents/agent_tool"
