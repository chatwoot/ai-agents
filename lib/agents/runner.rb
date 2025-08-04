# frozen_string_literal: true

require_relative "message_extractor"

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

    # Create a thread-safe agent runner for multi-agent conversations.
    # The first agent becomes the default entry point for new conversations.
    # All agents must be explicitly provided - no automatic discovery.
    #
    # @param agents [Array<Agents::Agent>] All agents that should be available for handoffs
    # @return [AgentRunner] Thread-safe runner that can be reused across multiple conversations
    #
    # @example
    #   runner = Agents::Runner.with_agents(triage_agent, billing_agent, support_agent)
    #   result = runner.run("I need help")  # Uses triage_agent for new conversation
    #   result = runner.run("More help", context: stored_context)  # Continues with appropriate agent
    def self.with_agents(*agents)
      AgentRunner.new(agents)
    end

    # Execute an agent with the given input and context.
    # This is now called internally by AgentRunner and should not be used directly.
    #
    # @param starting_agent [Agents::Agent] The agent to run
    # @param input [String] The user's input message
    # @param context [Hash] Shared context data accessible to all tools
    # @param registry [Hash] Registry of agents for handoff resolution
    # @param max_turns [Integer] Maximum conversation turns before stopping
    # @param callbacks [Hash] Optional callbacks for real-time event notifications
    # @return [RunResult] The result containing output, messages, and usage
    def run(starting_agent, input, context: {}, registry: {}, max_turns: DEFAULT_MAX_TURNS, callbacks: {})
      # The starting_agent is already determined by AgentRunner based on conversation history
      current_agent = starting_agent

      # Create context wrapper with deep copy for thread safety
      context_copy = deep_copy_context(context)
      context_wrapper = RunContext.new(context_copy, callbacks: callbacks)
      current_turn = 0

      # Create chat and restore conversation history
      chat = create_chat(current_agent, context_wrapper)
      restore_conversation_history(chat, context_wrapper)

      loop do
        current_turn += 1
        raise MaxTurnsExceeded, "Exceeded maximum turns: #{max_turns}" if current_turn > max_turns

        # Get response from LLM (Extended Chat handles tool execution with handoff detection)
        result = if current_turn == 1
                   # Emit agent thinking event for initial message
                   context_wrapper.callback_manager.emit_agent_thinking(current_agent.name, input)
                   chat.ask(input)
                 else
                   # Emit agent thinking event for continuation
                   context_wrapper.callback_manager.emit_agent_thinking(current_agent.name, "(continuing conversation)")
                   chat.complete
                 end
        response = result

        # Check for handoff response from our extended chat
        if response.is_a?(Agents::Chat::HandoffResponse)
          next_agent = response.target_agent

          # Validate that the target agent is in our registry
          # This prevents handoffs to agents that weren't explicitly provided
          unless registry[next_agent.name]
            puts "[Agents] Warning: Handoff to unregistered agent '#{next_agent.name}', continuing with current agent"
            next if response.tool_call?

            next
          end

          # Save current conversation state before switching
          save_conversation_state(chat, context_wrapper, current_agent)

          # Emit agent handoff event
          context_wrapper.callback_manager.emit_agent_handoff(current_agent.name, next_agent.name, "handoff")

          # Switch to new agent - store agent name for persistence
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
          messages: MessageExtractor.extract_messages(chat, current_agent),
          usage: context_wrapper.usage,
          context: context_wrapper.context
        )
      end
    rescue MaxTurnsExceeded => e
      # Save state even on error
      save_conversation_state(chat, context_wrapper, current_agent) if chat

      RunResult.new(
        output: "Conversation ended: #{e.message}",
        messages: chat ? MessageExtractor.extract_messages(chat, current_agent) : [],
        usage: context_wrapper.usage,
        error: e,
        context: context_wrapper.context
      )
    rescue StandardError => e
      # Save state even on error
      save_conversation_state(chat, context_wrapper, current_agent) if chat

      RunResult.new(
        output: nil,
        messages: chat ? MessageExtractor.extract_messages(chat, current_agent) : [],
        usage: context_wrapper.usage,
        error: e,
        context: context_wrapper.context
      )
    end

    private

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
        next unless %i[user assistant].include?(msg[:role].to_sym)
        next unless msg[:content] && !MessageExtractor.content_empty?(msg[:content])

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
      messages = MessageExtractor.extract_messages(chat, current_agent)

      # Update context with latest state
      context_wrapper.context[:conversation_history] = messages
      context_wrapper.context[:current_agent] = current_agent.name
      context_wrapper.context[:turn_count] = (context_wrapper.context[:turn_count] || 0) + 1
      context_wrapper.context[:last_updated] = Time.now

      # Clean up temporary handoff state
      context_wrapper.context.delete(:pending_handoff)
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
        temperature: agent.temperature,
        handoff_tools: handoff_tools,        # Direct tools, no wrapper
        context_wrapper: context_wrapper,    # Pass context directly
        response_schema: agent.response_schema # Pass structured output schema
      )

      chat.with_instructions(system_prompt) if system_prompt
      chat.with_tools(*wrapped_regular_tools) if wrapped_regular_tools.any?
      chat
    end
  end
end
