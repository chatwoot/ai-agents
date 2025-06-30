# frozen_string_literal: true

module Agents
  # The execution engine that orchestrates conversations between users and agents.
  # Runner manages the conversation flow, handles tool execution through RubyLLM,
  # coordinates handoffs between agents, and ensures thread-safe operation.
  #
  # The Runner follows a turn-based execution model where each turn consists of:
  # 1. Sending a message to the LLM with current context
  # 2. Receiving a response that may include tool calls
  # 3. Executing tools and getting results (handled by RubyLLM)
  # 4. Checking for agent handoffs
  # 5. Continuing until no more tools are called
  #
  # ## Thread Safety
  # The Runner ensures thread safety by:
  # - Creating new context wrappers for each execution
  # - Using tool wrappers that pass context through parameters
  # - Never storing execution state in shared variables
  #
  # ## Integration with RubyLLM
  # We leverage RubyLLM for LLM communication and tool execution while
  # maintaining our own context management and handoff logic.
  #
  # @example Simple conversation
  #   agent = Agents::Agent.new(
  #     name: "Assistant",
  #     instructions: "You are a helpful assistant",
  #     tools: [weather_tool]
  #   )
  #
  #   result = Agents::Runner.run(agent, "What's the weather?")
  #   puts result.output
  #   # => "Let me check the weather for you..."
  #
  # @example Conversation with context
  #   result = Agents::Runner.run(
  #     support_agent,
  #     "I need help with my order",
  #     context: { user_id: 123, order_id: 456 }
  #   )
  #
  # @example Multi-agent handoff
  #   triage = Agents::Agent.new(
  #     name: "Triage",
  #     instructions: "Route users to the right specialist",
  #     handoff_agents: [billing_agent, tech_agent]
  #   )
  #
  #   result = Agents::Runner.run(triage, "I can't pay my bill")
  #   # Triage agent will handoff to billing_agent
  class Runner
    DEFAULT_MAX_TURNS = 10

    class MaxTurnsExceeded < StandardError; end

    # Convenience class method for running agents
    def self.run(agent, input, context: {}, max_turns: DEFAULT_MAX_TURNS)
      # we build the registry only once, since the handoff graphs are stable
      # all the handoffs are supposed to be registerd before the runner is called
      # TODO: A lazy registry discovery can be implemented by using a memoization pattern
      # that can solve for the dynamic handoff registration, but we recommend that anyway
      # TODO: build a Agents::AgentRegistry class if we need to add more utils
      registry = build_agents_registry(agent)

      new.run(agent, input, context: context, max_turns: max_turns, registry: registry)
    end

    private_class_method def self.build_agents_registry(agent)
      # this is the registry that will hold all the agents and their names
      registry = {}

      # to ensure we don't end up in a recur
      visited = Set.new
      traverse_agent_handoffs(agent, registry, visited)

      registry
    end

    private_class_method def self.traverse_agent_handoffs(agent, registry, visited)
      return if visited.include?(agent)

      puts "Visiting agent #{agent.inspect}"
      visited.add(agent)
      # once the agent is visited, add it to the registry
      registry[agent.name] = agent

      agent.handoff_agents.each do |handoff_agent|
        traverse_agent_handoffs(handoff_agent, registry, visited)
      end
    end

    # Execute an agent with the given input and context
    #
    # @param starting_agent [Agents::Agent] The initial agent to run
    # @param input [String] The user's input message
    # @param context [Hash] Shared context data accessible to all tools
    # @param max_turns [Integer] Maximum conversation turns before stopping
    # @param registry [Hash] Registry of agents for handoff detection
    # @return [RunResult] The result containing output, messages, and usage
    def run(starting_agent, input, registry:, context: {}, max_turns: DEFAULT_MAX_TURNS)
      # Determine current agent from context or use starting agent
      current_agent = resolve_current_agent(registry, context[:current_agent]) || starting_agent

      # Create context wrapper with deep copy for thread safety
      context_copy = deep_copy_context(context)
      context_wrapper = RunContext.new(context_copy)
      current_turn = 0

      # Create chat and restore conversation history
      chat = create_chat(current_agent, context_wrapper)
      restore_conversation_history(chat, context_wrapper)

      loop do
        current_turn += 1
        raise MaxTurnsExceeded, "Exceeded maximum turns: #{max_turns}" if current_turn > max_turns

        # Get response from LLM (Extended Chat handles tool execution with handoff detection)
        result = if current_turn == 1
                   chat.ask(input)
                 else
                   chat.complete
                 end
        response = result

        # Check for handoff response from our extended chat
        if response.is_a?(Agents::Chat::HandoffResponse)
          next_agent = response.target_agent

          # Save current conversation state before switching
          save_conversation_state(chat, context_wrapper, current_agent)

          # Switch to new agent
          current_agent = next_agent
          context_wrapper.context[:current_agent] = next_agent.name

          # Create new chat for new agent with restored history
          chat = create_chat(current_agent, context_wrapper)
          restore_conversation_history(chat, context_wrapper)

          # Force the new agent to respond to the conversation context
          # This ensures the user gets a response from the new agent
          input = nil
          next
        end

        # If tools were called, continue the loop to let them execute
        next if response.tool_call?

        # If no tools were called, we have our final response

        # Save final state before returning
        save_conversation_state(chat, context_wrapper, current_agent)

        return RunResult.new(
          output: response.content,
          messages: extract_messages(chat),
          usage: context_wrapper.usage,
          context: context_wrapper.context
        )
      end
    rescue MaxTurnsExceeded => e
      # Save state even on error
      save_conversation_state(chat, context_wrapper, current_agent) if chat

      RunResult.new(
        output: "Conversation ended: #{e.message}",
        messages: chat ? extract_messages(chat) : [],
        usage: context_wrapper.usage,
        error: e,
        context: context_wrapper.context
      )
    rescue StandardError => e
      # Save state even on error
      save_conversation_state(chat, context_wrapper, current_agent) if chat

      RunResult.new(
        output: nil,
        messages: chat ? extract_messages(chat) : [],
        usage: context_wrapper.usage,
        error: e,
        context: context_wrapper.context
      )
    end

    private

    def resolve_current_agent(registry, current_agent_name)
      current_agent = registry[current_agent_name]
      return current_agent if current_agent.is_a?(Agents::Agent)

      nil
    end

    def deep_copy_context(context)
      # Handle deep copying for thread safety
      context.dup.tap do |copied|
        copied[:conversation_history] = context[:conversation_history]&.map(&:dup) || []
        # Don't copy agents - they're immutable
        copied[:current_agent] = context[:current_agent]
        copied[:turn_count] = context[:turn_count] || 0
      end
    end

    def restore_conversation_history(chat, context_wrapper)
      history = context_wrapper.context[:conversation_history] || []

      history.each do |msg|
        # Only restore user and assistant messages with content
        next unless %i[user assistant].include?(msg[:role])
        next unless msg[:content] && !msg[:content].strip.empty?

        chat.add_message(
          role: msg[:role].to_sym,
          content: msg[:content]
        )
      rescue StandardError => e
        # Continue with partial history on error
        puts "[Agents] Failed to restore message: #{e.message}"
      end
    rescue StandardError => e
      # If history restoration completely fails, continue with empty history
      puts "[Agents] Failed to restore conversation history: #{e.message}"
      context_wrapper.context[:conversation_history] = []
    end

    def save_conversation_state(chat, context_wrapper, current_agent)
      # Extract messages from chat
      messages = extract_messages(chat)

      # Update context with latest state
      context_wrapper.context[:conversation_history] = messages
      context_wrapper.context[:current_agent] = current_agent.name
      context_wrapper.context[:turn_count] = (context_wrapper.context[:turn_count] || 0) + 1
      context_wrapper.context[:last_updated] = Time.now

      # Clean up temporary handoff state
      context_wrapper.context.delete(:pending_handoff)
    rescue StandardError => e
      puts "[Agents] Failed to save conversation state: #{e.message}"
    end

    def create_chat(agent, context_wrapper)
      # Get system prompt (may be dynamic)
      system_prompt = agent.get_system_prompt(context_wrapper)

      # Separate handoff tools from regular tools
      handoff_tools = agent.handoff_agents.map { |target_agent| HandoffTool.new(target_agent) }
      regular_tools = agent.tools

      # Only wrap regular tools - handoff tools will be handled directly by Chat
      wrapped_regular_tools = regular_tools.map { |tool| ToolWrapper.new(tool, context_wrapper) }

      # Create extended chat with handoff awareness and context
      chat = Agents::Chat.new(
        model: agent.model,
        handoff_tools: handoff_tools,        # Direct tools, no wrapper
        context_wrapper: context_wrapper     # Pass context directly
      )

      chat.with_instructions(system_prompt) if system_prompt
      chat.with_tools(*wrapped_regular_tools) if wrapped_regular_tools.any?
      chat
    end

    def extract_messages(chat)
      return [] unless chat.respond_to?(:messages)

      chat.messages.filter_map do |msg|
        # Only include user and assistant messages with content
        next unless %i[user assistant].include?(msg.role)
        next unless msg.content && !msg.content.strip.empty?

        message = {
          role: msg.role,
          content: msg.content
        }

        message[:agent_name] = @current_agent_name if msg.role == :assistant && @current_agent_name

        message
      end
    end
  end
end
