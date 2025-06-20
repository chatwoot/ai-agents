# frozen_string_literal: true

require_relative "agents/version"

# Ruby Agents SDK - Production-ready multi-agent AI workflows
module Agents
  # Base error class for all Agents-related errors
  class Error < StandardError; end
  
  # Agent execution errors
  class ExecutionError < Error; end
  class ProviderError < Error; end
  class ConfigurationError < Error; end
  class ToolError < Error; end
  class HandoffError < Error; end
end

# Core components
require_relative "agents/configuration"
require_relative "agents/providers/base"
require_relative "agents/providers/openai"
require_relative "agents/providers/anthropic"
require_relative "agents/providers/registry"
require_relative "agents/context"
require_relative "agents/tool_base"
require_relative "agents/handoff"
require_relative "agents/agent"
require_relative "agents/runner"

# Optional components
require_relative "agents/tracing/tracer"
require_relative "agents/guardrails/manager"

module Agents
  # Recommended prompt prefix for agents that use handoffs
  HANDOFF_PROMPT_PREFIX = <<~PREFIX.freeze
    You are part of a multi-agent system. Agents can transfer conversations to other specialized agents when appropriate. 
    Transfer functions are named `transfer_to_<agent_name>`. 
    IMPORTANT: Never mention transfers or handoffs to users - simply call the transfer function when needed.
  PREFIX

  class << self
    # Configure the Agents SDK
    # @yield [Configuration] Configuration instance
    # @return [Configuration] The configuration
    def configure
      yield(configuration) if block_given?
      configuration
    end

    # Get the current configuration
    # @return [Configuration] The configuration instance
    def configuration
      @configuration ||= Configuration.new
    end

    # Configure tracing (optional)
    # @param config [Hash] Tracing configuration
    def configure_tracing(config = {})
      @tracer = Tracing::Tracer.new(config)
    end

    # Get global tracer instance
    # @return [Tracing::Tracer] Global tracer
    def tracer
      @tracer ||= Tracing::Tracer.new
    end

    # Start an agent trace
    def start_agent_trace(agent_class, input, context = {})
      tracer.start_agent_trace(agent_class, input, context)
    end

    # Start a tool trace
    def start_tool_trace(tool, method_name, params = {})
      tracer.start_tool_trace(tool, method_name, params)
    end

    # Start a handoff trace
    def start_handoff_trace(source_agent, target_agent, reason = nil, context = {})
      tracer.start_handoff_trace(source_agent, target_agent, reason, context)
    end
  end
end
