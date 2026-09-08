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
  #     .on_tool_start { |tool_name, args| broadcast_event('tool_start', tool_name, args) }
  #     .on_tool_complete { |tool_name, result| broadcast_event('tool_complete', tool_name, result) }
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
  # ## Callback Thread Safety
  # Callback registration is thread-safe using internal synchronization. Multiple threads
  # can safely register callbacks concurrently without data races.
  #
  class AgentRunner
    attr_reader :agents

    # Initialize with a list of agents. The first agent becomes the default entry point.
    #
    # @param agents [Array<Agents::Agent>] List of agents, first one is the default entry point
    def initialize(agents)
      raise ArgumentError, "At least one agent must be provided" if agents.empty?

      @agents = agents.dup.freeze
      @callbacks_mutex = Mutex.new
      @default_agent = agents.first

      # Build simple registry from provided agents - developer controls what's available
      @registry = build_registry(agents).freeze

      # Initialize callback storage - use thread-safe arrays
      @callbacks = CallbackManager::EVENT_TYPES.to_h { |event| [event, []] }
    end

    # Execute a conversation turn with automatic agent selection.
    # For new conversations, uses the default agent (first in the list).
    # For continuing conversations, determines the appropriate agent from conversation history.
    #
    # @param input [String] User's message
    # @param context [Hash] Conversation context (will be restored if continuing conversation)
    # @param max_turns [Integer] Maximum turns before stopping (default: 10)
    # @param headers [Hash, nil] Custom HTTP headers to pass through to the underlying LLM provider
    # @param params [Hash, nil] Provider-specific parameters to pass through to the underlying LLM (e.g., service_tier)
    # @return [RunResult] Execution result with output, messages, and updated context
    def run(input = nil, context: {}, max_turns: Runner::DEFAULT_MAX_TURNS, headers: nil, params: nil, chat: nil)
      context = context.transform_keys(&:to_sym)
      # Determine which agent should handle this conversation
      # Uses conversation history to maintain continuity across handoffs
      current_agent = determine_conversation_agent(context)
      # Execute using stateless Runner - each execution is independent and thread-safe
      # Pass callbacks to enable real-time event notifications
      Runner.new.run(
        current_agent,
        input,
        context: context,
        registry: @registry,
        max_turns: max_turns,
        headers: headers,
        params: params,
        callbacks: @callbacks,
        **(chat ? { chat: chat } : {})
      )
    end

    # Keep native approval decisions on the live chat; do not rebuild them from history.
    def resume(result, **options)
      raise ArgumentError, "Cannot resume a result without a chat" unless result.chat
      raise ArgumentError, "The result's active agent is not registered" unless @registry[result.context[:current_agent]]

      options = (result.request_options || {}).merge(options) do |key, previous, override|
        Helpers::HashNormalizer.merge(previous, Helpers::HashNormalizer.normalize(override, label: key.to_s))
      end
      run(nil, context: result.context, chat: result.chat, **options)
    end

    # All callbacks share registration, synchronization, and chaining semantics.
    CallbackManager::EVENT_TYPES.each do |event|
      define_method("on_#{event}") do |&block|
        @callbacks_mutex.synchronize { @callbacks[event] << block } if block
        self
      end
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
      active_agent = @registry[context[:current_agent] || context["current_agent"]]
      return active_agent if active_agent

      history = context[:conversation_history] || []

      # For new conversations, use the default (first) agent
      return @default_agent if history.empty?

      # Find the last assistant message with agent attribution
      # We traverse in reverse to find the most recent agent that spoke
      last_agent_name = history.reverse.find do |msg|
        (msg[:role] || msg["role"]).to_s == "assistant" && (msg[:agent_name] || msg["agent_name"])
      end
      last_agent_name = last_agent_name && (last_agent_name[:agent_name] || last_agent_name["agent_name"])

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
