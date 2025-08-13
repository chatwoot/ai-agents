# frozen_string_literal: true

require_relative "message_extractor"
require_relative "handoff_descriptor"

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

      # Create chat once and restore conversation history if any
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

        # Check for handoff descriptor - direct continuation approach
        if (descriptor = context_wrapper.context.delete(:pending_handoff_descriptor))
          next_agent = descriptor.target_agent

          # Validate that the target agent is in our registry
          # This prevents handoffs to agents that weren't explicitly provided
          unless registry[next_agent.name]
            puts "[Agents] Warning: Handoff to unregistered agent '#{next_agent.name}', continuing with current agent"
            # Continue with current agent, treating descriptor message as normal response
            next
          end

          # Emit agent handoff event
          context_wrapper.callback_manager.emit_agent_handoff(current_agent.name, next_agent.name, "handoff")

          # Switch to new agent atomically - all mutations in one place
          current_agent = next_agent
          context_wrapper.context[:current_agent] = next_agent.name

          # Reconfigure the existing chat for the new agent
          reconfigure_chat_for_agent(chat, current_agent, context_wrapper)

          # LLM continues naturally with the new agent context
          # No need to force continuation - it happens automatically
          next
        end

        # Handle regular halts (non-handoff) - return the halt content as final response
        if response.is_a?(RubyLLM::Tool::Halt)
          update_conversation_context(context_wrapper, current_agent)
          return RunResult.new(
            output: response.content,
            messages: MessageExtractor.extract_messages(chat, current_agent),
            usage: context_wrapper.usage,
            context: context_wrapper.context
          )
        end

        # If tools were called, continue the loop to let them execute
        next if response.tool_call?

        # If no tools were called, we have our final response

        # Update final context before returning
        update_conversation_context(context_wrapper, current_agent)

        return RunResult.new(
          output: response.content,
          messages: MessageExtractor.extract_messages(chat, current_agent),
          usage: context_wrapper.usage,
          context: context_wrapper.context
        )
      end
    rescue MaxTurnsExceeded => e
      # Update context even on error
      update_conversation_context(context_wrapper, current_agent) if chat && current_agent

      RunResult.new(
        output: "Conversation ended: #{e.message}",
        messages: chat ? MessageExtractor.extract_messages(chat, current_agent) : [],
        usage: context_wrapper.usage,
        error: e,
        context: context_wrapper.context
      )
    rescue StandardError => e
      # Update context even on error
      update_conversation_context(context_wrapper, current_agent) if chat && current_agent

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

    # Restore conversation history from context into chat
    # This method is now only called once during initial chat creation
    # since we maintain a single chat instance throughout handoffs
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

    # Reconfigure an existing chat instance for a new agent using RubyLLM's replace option
    # This eliminates the need to create new chats and restore history on handoffs
    def reconfigure_chat_for_agent(chat, agent, context_wrapper)
      # Get system prompt for the new agent (may be dynamic)
      system_prompt = agent.get_system_prompt(context_wrapper)

      # Build tools for the new agent
      all_tools = build_agent_tools(agent, context_wrapper)

      # Use RubyLLM's replace option to swap configuration
      chat.with_instructions(system_prompt, replace: true) if system_prompt
      chat.with_tools(*all_tools, replace: true) if all_tools.any?
      chat.with_temperature(agent.temperature) if agent.temperature
      chat.with_schema(agent.response_schema) if agent.response_schema

      chat
    end

    # Update conversation context with current state
    # Simplified version that doesn't need to save/restore full conversation history
    def update_conversation_context(context_wrapper, current_agent)
      context_wrapper.context[:current_agent] = current_agent.name
      context_wrapper.context[:turn_count] = (context_wrapper.context[:turn_count] || 0) + 1
      context_wrapper.context[:last_updated] = Time.now

      # Clean up temporary handoff state
      context_wrapper.context.delete(:pending_handoff_descriptor)
    end

    def create_chat(agent, context_wrapper)
      # Get system prompt (may be dynamic)
      system_prompt = agent.get_system_prompt(context_wrapper)

      # Create standard RubyLLM chat
      chat = RubyLLM::Chat.new(model: agent.model)

      # Build tools for the agent
      all_tools = build_agent_tools(agent, context_wrapper)

      # Configure chat with instructions, temperature, tools, and schema
      chat.with_instructions(system_prompt) if system_prompt
      chat.with_temperature(agent.temperature) if agent.temperature
      chat.with_tools(*all_tools) if all_tools.any?
      chat.with_schema(agent.response_schema) if agent.response_schema

      chat
    end

    # Build tools for an agent - both handoff and regular tools need wrapping
    # Extracted to a separate method to reduce duplication between create_chat and reconfigure_chat_for_agent
    def build_agent_tools(agent, context_wrapper)
      all_tools = []

      # Add handoff tools
      agent.handoff_agents.each do |target_agent|
        handoff_tool = HandoffTool.new(target_agent)
        all_tools << ToolWrapper.new(handoff_tool, context_wrapper)
      end

      # Add regular tools
      agent.tools.each do |tool|
        all_tools << ToolWrapper.new(tool, context_wrapper)
      end

      all_tools
    end
  end
end
