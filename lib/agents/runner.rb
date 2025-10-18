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
    class AgentNotFoundError < StandardError; end

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
    # @param headers [Hash, nil] Custom HTTP headers passed to the underlying LLM provider
    # @param callbacks [Hash] Optional callbacks for real-time event notifications
    # @return [RunResult] The result containing output, messages, and usage
    def run(starting_agent, input, context: {}, registry: {}, max_turns: DEFAULT_MAX_TURNS, headers: nil, callbacks: {})
      # The starting_agent is already determined by AgentRunner based on conversation history
      current_agent = starting_agent

      # Create context wrapper with deep copy for thread safety
      context_copy = deep_copy_context(context)
      context_wrapper = RunContext.new(context_copy, callbacks: callbacks)
      current_turn = 0

      # Emit run start event
      context_wrapper.callback_manager.emit_run_start(current_agent.name, input, context_wrapper)

      # Wrap entire execution in agent span if tracing is enabled
      execute_with_tracing(current_agent, input, context_wrapper, registry, max_turns, headers)
    end

    private

    # Main execution method wrapped in tracing span
    def execute_with_tracing(starting_agent, input, context_wrapper, registry, max_turns, headers)
      current_agent = starting_agent

      # Create span for agent execution
      Tracing.agent_span(current_agent.name, model: current_agent.model) do |span|
        execute_agent_loop(current_agent, input, context_wrapper, registry, max_turns, headers, span)
      end
    rescue MaxTurnsExceeded => e
      handle_max_turns_error(e, nil, context_wrapper, starting_agent)
    rescue StandardError => e
      handle_standard_error(e, nil, context_wrapper, starting_agent)
    end

    # Main agent execution loop
    def execute_agent_loop(starting_agent, input, context_wrapper, registry, max_turns, headers, span)
      current_agent = starting_agent
      current_turn = 0

      runtime_headers = Helpers::Headers.normalize(headers)
      agent_headers = Helpers::Headers.normalize(starting_agent.headers)

      # Create chat and restore conversation history
      chat = RubyLLM::Chat.new(model: starting_agent.model)
      current_headers = Helpers::Headers.merge(agent_headers, runtime_headers)
      apply_headers(chat, current_headers)
      configure_chat_for_agent(chat, starting_agent, context_wrapper, replace: false)
      restore_conversation_history(chat, context_wrapper)

      loop do
        current_turn += 1
        raise MaxTurnsExceeded, "Exceeded maximum turns: #{max_turns}" if current_turn > max_turns

        # Get response from LLM (RubyLLM handles tool execution with halting based handoff detection)
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

        # Check for handoff via RubyLLM's halt mechanism
        if response.is_a?(RubyLLM::Tool::Halt) && context_wrapper.context[:pending_handoff]
          handoff_info = context_wrapper.context.delete(:pending_handoff)
          next_agent = handoff_info[:target_agent]

          # Validate that the target agent is in our registry
          # This prevents handoffs to agents that weren't explicitly provided
          unless registry[next_agent.name]
            save_conversation_state(chat, context_wrapper, current_agent)
            error = AgentNotFoundError.new("Handoff failed: Agent '#{next_agent.name}' not found in registry")
            result = RunResult.new(
              output: nil,
              messages: Helpers::MessageExtractor.extract_messages(chat, current_agent),
              usage: context_wrapper.usage,
              context: context_wrapper.context,
              error: error
            )

            # Emit agent complete and run complete events with error
            context_wrapper.callback_manager.emit_agent_complete(current_agent.name, result, error, context_wrapper)
            context_wrapper.callback_manager.emit_run_complete(current_agent.name, result, context_wrapper)
            return result
          end

          # Save current conversation state before switching
          save_conversation_state(chat, context_wrapper, current_agent)

          # Emit agent complete event before handoff
          context_wrapper.callback_manager.emit_agent_complete(current_agent.name, nil, nil, context_wrapper)

          # Emit agent handoff event
          context_wrapper.callback_manager.emit_agent_handoff(current_agent.name, next_agent.name, "handoff")

          # Record handoff in current span
          span.add_event("agent.handoff", attributes: {
                           "handoff.from_agent" => current_agent.name,
                           "handoff.to_agent" => next_agent.name,
                           "handoff.reason" => "handoff"
                         })

          # Switch to new agent - store agent name for persistence
          current_agent = next_agent
          context_wrapper.context[:current_agent] = next_agent.name

          # Create new span for the handoff agent
          return Tracing.agent_span(current_agent.name, model: current_agent.model) do |new_span|
            # Reconfigure existing chat for new agent - preserves conversation history automatically
            configure_chat_for_agent(chat, current_agent, context_wrapper, replace: true)
            agent_headers = Helpers::Headers.normalize(current_agent.headers)
            current_headers = Helpers::Headers.merge(agent_headers, runtime_headers)
            apply_headers(chat, current_headers)

            # Continue execution with new agent in new span
            continue_agent_loop(chat, current_agent, context_wrapper, registry, max_turns, headers,
                                runtime_headers, current_turn, new_span)
          end
        end

        # Handle non-handoff halts
        return finalize_result(chat, context_wrapper, current_agent, response.content) if response.is_a?(RubyLLM::Tool::Halt)

        # Continue if tools were called
        next if response.tool_call?

        # Final response
        return finalize_result(chat, context_wrapper, current_agent, response.content)
      end
    rescue MaxTurnsExceeded => e
      handle_max_turns_error(e, chat, context_wrapper, current_agent)
    rescue StandardError => e
      handle_standard_error(e, chat, context_wrapper, current_agent)
    end

    # Continue agent execution loop after handoff (runs in new span)
    def continue_agent_loop(chat, current_agent, context_wrapper, registry, max_turns, headers,
                            runtime_headers, current_turn, span)
      loop do
        current_turn += 1
        raise MaxTurnsExceeded, "Exceeded maximum turns: #{max_turns}" if current_turn > max_turns

        # Force the new agent to respond to the conversation context
        context_wrapper.callback_manager.emit_agent_thinking(current_agent.name, "(continuing conversation)")
        response = chat.complete

        # Check for handoff
        if response.is_a?(RubyLLM::Tool::Halt) && context_wrapper.context[:pending_handoff]
          handoff_info = context_wrapper.context.delete(:pending_handoff)
          next_agent = handoff_info[:target_agent]

          unless registry[next_agent.name]
            save_conversation_state(chat, context_wrapper, current_agent)
            error = AgentNotFoundError.new("Handoff failed: Agent '#{next_agent.name}' not found in registry")
            result = create_error_result(chat, context_wrapper, current_agent, error)
            context_wrapper.callback_manager.emit_agent_complete(current_agent.name, result, error, context_wrapper)
            context_wrapper.callback_manager.emit_run_complete(current_agent.name, result, context_wrapper)
            return result
          end

          save_conversation_state(chat, context_wrapper, current_agent)
          context_wrapper.callback_manager.emit_agent_complete(current_agent.name, nil, nil, context_wrapper)
          context_wrapper.callback_manager.emit_agent_handoff(current_agent.name, next_agent.name, "handoff")

          # Record handoff event
          span.add_event("agent.handoff", attributes: {
                           "handoff.from_agent" => current_agent.name,
                           "handoff.to_agent" => next_agent.name,
                           "handoff.reason" => "handoff"
                         })

          current_agent = next_agent
          context_wrapper.context[:current_agent] = next_agent.name

          # Create new span for handoff and continue
          return Tracing.agent_span(current_agent.name, model: current_agent.model) do |new_span|
            configure_chat_for_agent(chat, current_agent, context_wrapper, replace: true)
            agent_headers = Helpers::Headers.normalize(current_agent.headers)
            current_headers = Helpers::Headers.merge(agent_headers, runtime_headers)
            apply_headers(chat, current_headers)
            continue_agent_loop(chat, current_agent, context_wrapper, registry, max_turns, headers,
                                runtime_headers, current_turn, new_span)
          end
        end

        # Handle non-handoff halts
        if response.is_a?(RubyLLM::Tool::Halt)
          return finalize_result(chat, context_wrapper, current_agent, response.content)
        end

        # Continue if tools were called
        next if response.tool_call?

        # Final response
        return finalize_result(chat, context_wrapper, current_agent, response.content)
      end
    rescue MaxTurnsExceeded => e
      handle_max_turns_error(e, chat, context_wrapper, current_agent)
    rescue StandardError => e
      handle_standard_error(e, chat, context_wrapper, current_agent)
    end

    # Finalize successful result
    def finalize_result(chat, context_wrapper, current_agent, output)
      save_conversation_state(chat, context_wrapper, current_agent)

      result = RunResult.new(
        output: output,
        messages: Helpers::MessageExtractor.extract_messages(chat, current_agent),
        usage: context_wrapper.usage,
        context: context_wrapper.context
      )

      context_wrapper.callback_manager.emit_agent_complete(current_agent.name, result, nil, context_wrapper)
      context_wrapper.callback_manager.emit_run_complete(current_agent.name, result, context_wrapper)

      # Add usage metadata to span
      if Tracing.enabled?
        Tracing.current_span&.set_attribute("gen_ai.usage.input_tokens", context_wrapper.usage.input_tokens)
        Tracing.current_span&.set_attribute("gen_ai.usage.output_tokens", context_wrapper.usage.output_tokens)
      end

      result
    end

    # Create error result
    def create_error_result(chat, context_wrapper, current_agent, error)
      RunResult.new(
        output: nil,
        messages: chat ? Helpers::MessageExtractor.extract_messages(chat, current_agent) : [],
        usage: context_wrapper.usage,
        context: context_wrapper.context,
        error: error
      )
    end

    # Handle MaxTurnsExceeded error
    def handle_max_turns_error(error, chat, context_wrapper, current_agent)
      save_conversation_state(chat, context_wrapper, current_agent) if chat

      result = RunResult.new(
        output: "Conversation ended: #{error.message}",
        messages: chat ? Helpers::MessageExtractor.extract_messages(chat, current_agent) : [],
        usage: context_wrapper.usage,
        error: error,
        context: context_wrapper.context
      )

      context_wrapper.callback_manager.emit_agent_complete(current_agent.name, result, error, context_wrapper)
      context_wrapper.callback_manager.emit_run_complete(current_agent.name, result, context_wrapper)

      # Record error in span
      Tracing.current_span&.record_exception(error) if Tracing.enabled?

      result
    end

    # Handle standard errors
    def handle_standard_error(error, chat, context_wrapper, current_agent)
      save_conversation_state(chat, context_wrapper, current_agent) if chat

      result = RunResult.new(
        output: nil,
        messages: chat ? Helpers::MessageExtractor.extract_messages(chat, current_agent) : [],
        usage: context_wrapper.usage,
        error: error,
        context: context_wrapper.context
      )

      context_wrapper.callback_manager.emit_agent_complete(current_agent.name, result, error, context_wrapper)
      context_wrapper.callback_manager.emit_run_complete(current_agent.name, result, context_wrapper)

      # Record error in span
      Tracing.current_span&.record_exception(error) if Tracing.enabled?

      result
    end

    # Creates a deep copy of context data for thread safety.
    # Preserves conversation history array structure while avoiding agent mutation.
    #
    # @param context [Hash] The context to copy
    # @return [Hash] Thread-safe deep copy of the context
    def deep_copy_context(context)
      # Handle deep copying for thread safety
      context.dup.tap do |copied|
        copied[:conversation_history] = context[:conversation_history]&.map(&:dup) || []
        # Don't copy agents - they're immutable
        copied[:current_agent] = context[:current_agent]
        copied[:turn_count] = context[:turn_count] || 0
      end
    end

    # Restores conversation history from context into RubyLLM chat.
    # Converts stored message hashes back into RubyLLM::Message objects with proper content handling.
    #
    # @param chat [RubyLLM::Chat] The chat instance to restore history into
    # @param context_wrapper [RunContext] Context containing conversation history
    def restore_conversation_history(chat, context_wrapper)
      history = context_wrapper.context[:conversation_history] || []

      history.each do |msg|
        # Only restore user and assistant messages with content
        next unless %i[user assistant].include?(msg[:role].to_sym)
        next unless msg[:content] && !Helpers::MessageExtractor.content_empty?(msg[:content])

        # Extract text content safely - handle both string and hash content
        content = RubyLLM::Content.new(msg[:content])

        # Create a proper RubyLLM::Message and pass it to add_message
        message = RubyLLM::Message.new(
          role: msg[:role].to_sym,
          content: content
        )
        chat.add_message(message)
      end
    end

    # Saves current conversation state from RubyLLM chat back to context for persistence.
    # Maintains conversation continuity across agent handoffs and process boundaries.
    #
    # @param chat [RubyLLM::Chat] The chat instance to extract state from
    # @param context_wrapper [RunContext] Context to save state into
    # @param current_agent [Agents::Agent] The currently active agent
    def save_conversation_state(chat, context_wrapper, current_agent)
      # Extract messages from chat
      messages = Helpers::MessageExtractor.extract_messages(chat, current_agent)

      # Update context with latest state
      context_wrapper.context[:conversation_history] = messages
      context_wrapper.context[:current_agent] = current_agent.name
      context_wrapper.context[:turn_count] = (context_wrapper.context[:turn_count] || 0) + 1
      context_wrapper.context[:last_updated] = Time.now

      # Clean up temporary handoff state
      context_wrapper.context.delete(:pending_handoff)
    end

    # Configures a RubyLLM chat instance with agent-specific settings.
    # Uses RubyLLM's replace option to swap agent context while preserving conversation history during handoffs.
    #
    # @param chat [RubyLLM::Chat] The chat instance to configure
    # @param agent [Agents::Agent] The agent whose configuration to apply
    # @param context_wrapper [RunContext] Thread-safe context wrapper
    # @param replace [Boolean] Whether to replace existing configuration (true for handoffs, false for initial setup)
    # @return [RubyLLM::Chat] The configured chat instance
    def configure_chat_for_agent(chat, agent, context_wrapper, replace: false)
      # Get system prompt (may be dynamic)
      system_prompt = agent.get_system_prompt(context_wrapper)

      # Combine all tools - both handoff and regular tools need wrapping
      all_tools = build_agent_tools(agent, context_wrapper)

      # Switch model if different (important for handoffs between agents using different models)
      chat.with_model(agent.model) if replace

      # Configure chat with instructions, temperature, tools, and schema
      chat.with_instructions(system_prompt, replace: replace) if system_prompt
      chat.with_temperature(agent.temperature) if agent.temperature
      chat.with_tools(*all_tools, replace: replace)
      chat.with_schema(agent.response_schema) if agent.response_schema

      chat
    end

    def apply_headers(chat, headers)
      return if headers.empty?

      chat.with_headers(**headers)
    end

    # Builds thread-safe tool wrappers for an agent's tools and handoff tools.
    #
    # @param agent [Agents::Agent] The agent whose tools to wrap
    # @param context_wrapper [RunContext] Thread-safe context wrapper for tool execution
    # @return [Array<ToolWrapper>] Array of wrapped tools ready for RubyLLM
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
