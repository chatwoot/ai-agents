# frozen_string_literal: true

module Agents
  # Thread-safe agent execution manager that provides a clean API for multi-agent conversations.
  # This class is designed to be created once and reused across multiple threads safely.
  #
  # The key insight here is separating agent registry/configuration (this class) from
  # execution state (Runner instances). This allows the same AgentRunner to be used
  # concurrently without thread safety issues.
  #
  # ## Usage Pattern
  #   # Create once (typically at application startup)
  #   runner = Agents::Runner.with_agents(triage_agent, billing_agent, support_agent)
  #
  #   # Use safely from multiple threads
  #   result = runner.run("I need billing help")           # New conversation
  #   result = runner.run("More help", context: context)   # Continue conversation
  #
  # ## Thread Safety Design
  # - All instance variables are frozen after initialization (immutable state)
  # - Agent registry is built once and never modified
  # - Each run() call creates independent execution context
  # - No shared mutable state between concurrent executions
  #
  class AgentRunner
    # Initialize with a list of agents. The first agent becomes the default entry point.
    #
    # @param agents [Array<Agents::Agent>] List of agents, first one is the default entry point
    def initialize(agents)
      raise ArgumentError, "At least one agent must be provided" if agents.empty?

      @agents = agents.dup.freeze
      @default_agent = agents.first

      # Build simple registry from provided agents - developer controls what's available
      @registry = build_registry(agents).freeze
    end

    # Execute a conversation turn with automatic agent selection.
    # For new conversations, uses the default agent (first in the list).
    # For continuing conversations, determines the appropriate agent from conversation history.
    #
    # @param input [String] User's message
    # @param context [Hash] Conversation context (will be restored if continuing conversation)
    # @param max_turns [Integer] Maximum turns before stopping (default: 10)
    # @return [RunResult] Execution result with output, messages, and updated context
    def run(input, context: {}, max_turns: Runner::DEFAULT_MAX_TURNS)
      # Determine which agent should handle this conversation
      # Uses conversation history to maintain continuity across handoffs
      current_agent = determine_conversation_agent(context)

      # Execute using stateless Runner - each execution is independent and thread-safe
      Runner.new.run(
        current_agent,
        input,
        context: context,
        registry: @registry,
        max_turns: max_turns
      )
    end

    private

    # Build agent registry from provided agents only.
    # Developer explicitly controls which agents are available for handoffs.
    #
    # @param agents [Array<Agents::Agent>] Agents to register
    # @return [Hash<String, Agents::Agent>] Registry mapping agent names to agent instances
    def build_registry(agents)
      registry = {}
      agents.each { |agent| registry[agent.name] = agent }
      registry
    end

    # Determine which agent should handle the current conversation.
    # For new conversations (empty context), uses the default agent.
    # For continuing conversations, analyzes history to find the last agent that spoke.
    #
    # This implements Google ADK-style session continuation logic where the system
    # automatically maintains conversation continuity without requiring manual agent tracking.
    #
    # @param context [Hash] Conversation context with potential history
    # @return [Agents::Agent] Agent that should handle this conversation turn
    def determine_conversation_agent(context)
      history = context[:conversation_history] || []

      # For new conversations, use the default (first) agent
      return @default_agent if history.empty?

      # Find the last assistant message with agent attribution
      # We traverse in reverse to find the most recent agent that spoke
      last_agent_name = history.reverse.find do |msg|
        msg[:role] == :assistant && msg[:agent_name]
      end&.dig(:agent_name)

      # Try to resolve from registry, fall back to default if agent not found
      # This handles cases where agent names in history don't match current registry
      if last_agent_name && @registry[last_agent_name]
        @registry[last_agent_name]
      else
        @default_agent
      end
    end
  end
end
