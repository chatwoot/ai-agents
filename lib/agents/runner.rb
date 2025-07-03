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
      new.run(agent, input, context: context, max_turns: max_turns)
    end

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

    # Execute an agent with the given input and context
    #
    # @param starting_agent [Agents::Agent] The initial agent to run
    # @param input [String] The user's input message
    # @param context [Hash] Shared context data accessible to all tools
    # @param registry [Hash] Registry of agents for handoff resolution
    # @param max_turns [Integer] Maximum conversation turns before stopping
    # @return [RunResult] The result containing output, messages, and usage
    def run(starting_agent, input, context: {}, registry: {}, max_turns: DEFAULT_MAX_TURNS)
      # Use starting agent if provided, otherwise resolve from context
      current_agent = starting_agent || resolve_agent_from_context(context[:current_agent], registry)

      # Create context wrapper with deep copy for thread safety
      context_copy = deep_copy_context(context)
      # Store the resolved agent name in context
      context_copy[:current_agent] = current_agent.name
      context_wrapper = RunContext.new(context_copy)
      current_turn = 0

      # Create chat and restore conversation history
      chat = create_chat(current_agent, context_wrapper)
      restore_conversation_history(chat, context_wrapper)

      loop do
        current_turn += 1
        raise MaxTurnsExceeded, "Exceeded maximum turns: #{max_turns}" if current_turn > max_turns

        # Get response from LLM (RubyLLM handles tool execution)
        response = if current_turn == 1
                     chat.ask(input)
                   else
                     chat.complete
                   end

        # Update usage
        context_wrapper.usage.add(response.usage) if response.respond_to?(:usage) && response.usage

        # Check for handoff via HandoffResponse (from Agents::Chat)
        if response.is_a?(Chat::HandoffResponse)
          next_agent = response.target_agent
          handoff_message = response.handoff_message

          # Validate that the target agent is in our registry if registry is provided
          if registry.any? && !registry[next_agent.name]
            puts "[Agents] Warning: Handoff to unregistered agent '#{next_agent.name}', continuing with current agent"
            next if response.tool_call?

            next
          end

          Agents.logger.info "Handoff from #{current_agent.name} to #{next_agent.name}"

          # Save current conversation state before switching
          save_conversation_state(chat, context_wrapper, current_agent)

          # Create new context wrapper for next agent
          next_context = context_wrapper.context.dup
          next_context[:current_agent] = next_agent.name
          next_context[:handoff_message] = handoff_message

          # Continue with the next agent using the handoff message as input
          return run(
            next_agent,
            handoff_message,
            context: next_context,
            registry: registry,
            max_turns: max_turns
          )
        end

        # Check completion conditions after potential handoff
        next if response.tool_call?

        final_content = response.content || ""

        save_conversation_state(chat, context_wrapper, current_agent)

        return RunResult.new(
          output: final_content,
          messages: extract_messages(chat),
          usage: context_wrapper.usage,
          error: nil,
          context: context_wrapper.context
        )

        # Continue loop for tool execution (handled by RubyLLM)
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

      Agents.logger.error "FATAL ERROR: #{e.message}"
      Agents.logger.error "Error class: #{e.class}"
      Agents.logger.debug "Backtrace: #{e.backtrace.first(10).join("\n  ")}"

      RunResult.new(
        output: nil,
        messages: chat ? extract_messages(chat) : [],
        usage: context_wrapper.usage,
        error: e,
        context: context_wrapper.context
      )
    end

    private

    def resolve_agent_from_context(agent_ref, registry)
      return nil unless agent_ref

      # If it's already an agent object, return it
      return agent_ref if agent_ref.respond_to?(:name)

      # If it's a string and we have a registry, look it up
      if agent_ref.is_a?(String) && registry[agent_ref]
        return registry[agent_ref]
      end

      # Return nil if we couldn't resolve it
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
        Agents.logger.warn "Failed to restore message: #{e.message}"
      end
    rescue StandardError => e
      # If history restoration completely fails, continue with empty history
      Agents.logger.warn "Failed to restore conversation history: #{e.message}"
      context_wrapper.context[:conversation_history] = []
    end

    def save_conversation_state(chat, context_wrapper, current_agent)
      # Extract messages from chat
      messages = extract_messages(chat)

      # Validate messages before saving
      valid_messages = messages.select do |msg|
        msg.is_a?(Hash) && msg[:role] && (msg[:content] || msg[:tool_calls])
      end

      # Update context with latest state
      context_wrapper.context[:conversation_history] = valid_messages
      context_wrapper.context[:current_agent] = current_agent.name
      context_wrapper.context[:turn_count] = (context_wrapper.context[:turn_count] || 0) + 1
      context_wrapper.context[:last_updated] = Time.now
    rescue StandardError => e
      Agents.logger.warn "Failed to save conversation state: #{e.message}"
      Agents.logger.debug "Error details: #{e.class} - #{e.backtrace&.first(3)&.join("\n  ")}"

      # Set a minimal valid state to prevent cascading errors
      context_wrapper.context[:conversation_history] = []
    end

    def create_chat(agent, context_wrapper)
      # Get system prompt (may be dynamic)
      system_prompt = agent.get_system_prompt(context_wrapper)

      # Separate handoff tools from regular tools for handoff detection
      all_tools = agent.all_tools
      handoff_tools = all_tools.select { |tool| tool.is_a?(HandoffTool) }
      regular_tools = all_tools - handoff_tools

      # Handle tool wrapping with dual interface:
      # - MCP tools work directly with RubyLLM (they have a 'call' method)
      # - Regular Agents::Tool instances need ToolWrapper for context injection
      wrapped_tools = regular_tools.map do |tool|
        tool_name = tool.respond_to?(:name) ? tool.name : tool.class.name
        is_mcp = tool.respond_to?(:mcp_tool?) && tool.mcp_tool?

        if is_mcp
          # MCP tools work directly with RubyLLM - they inherit from Agents::Tool
          # but also have the 'call' method that RubyLLM expects
          tool
        else
          # Regular Agents::Tool instances need wrapping for context injection
          ToolWrapper.new(tool, context_wrapper)
        end
      end

      if Agents.logger.debug?
        Agents.logger.debug "Total tools for chat: #{wrapped_tools.length + handoff_tools.length}"
        wrapped_tools.each_with_index do |tool, i|
          tool_name = tool.respond_to?(:name) ? tool.name : tool.class.name
          Agents.logger.debug "  #{i + 1}. #{tool_name} (#{tool.class})"
        end
        handoff_tools.each_with_index do |tool, i|
          tool_name = tool.respond_to?(:name) ? tool.name : tool.class.name
          Agents.logger.debug "  #{i + 1 + wrapped_tools.length}. #{tool_name} (#{tool.class}) [HANDOFF]"
        end
      end

      # Use Agents::Chat instead of RubyLLM.chat for handoff detection
      chat = Chat.new(
        model: agent.model,
        handoff_tools: handoff_tools,
        context_wrapper: context_wrapper
      )
      chat.with_instructions(system_prompt) if system_prompt
      chat.with_tools(*wrapped_tools) if wrapped_tools.any?
      chat
    end

    def extract_messages(chat)
      return [] unless chat.respond_to?(:messages)

      chat.messages.filter_map do |msg|
        case msg.role
        when :user
          extract_user_message(msg)
        when :assistant
          extract_assistant_message(msg)
        when :tool
          extract_tool_message(msg)
        end
      rescue StandardError => e
        Agents.logger.debug "Failed to extract message (role: #{msg.role}): #{e.message}"
        nil
      end
    end

    private

    def extract_user_message(msg)
      return nil unless msg.content&.strip&.length&.positive?

      { role: msg.role, content: msg.content }
    end

    def extract_assistant_message(msg)
      message_data = { role: msg.role }

      # Add content if present and non-empty
      message_data[:content] = msg.content if msg.content&.strip&.length&.positive?

      # Add tool calls if present
      if msg.respond_to?(:tool_calls) && msg.tool_calls&.any?
        begin
          normalized_calls = msg.tool_calls.filter_map do |tc|
            normalize_tool_call(tc)
          rescue StandardError => e
            Agents.logger.debug "Failed to normalize tool call: #{e.message}"
            nil
          end
          message_data[:tool_calls] = normalized_calls if normalized_calls.any?
        rescue StandardError => e
          Agents.logger.debug "Failed to process tool calls: #{e.message}"
        end
      end

      # Only return if message has content or tool calls
      message_data if message_data[:content] || message_data[:tool_calls]
    end

    def extract_tool_message(msg)
      {
        role: msg.role,
        content: msg.content,
        tool_call_id: msg.respond_to?(:tool_call_id) ? msg.tool_call_id : nil
      }.compact
    end

    def normalize_tool_call(tool_call)
      # Handle object format (standard)
      if tool_call.respond_to?(:id) && tool_call.respond_to?(:function)
        # Ensure arguments is properly formatted as a JSON string
        arguments = tool_call.function.arguments
        arguments = arguments.to_json if arguments.is_a?(Hash)
        arguments = arguments.to_s unless arguments.is_a?(String)

        {
          id: tool_call.id,
          type: tool_call.respond_to?(:type) ? tool_call.type : "function",
          function: {
            name: tool_call.function.name,
            arguments: arguments
          }
        }
      else
        # Handle hash format (fallback)
        normalized = tool_call.is_a?(Hash) ? tool_call : tool_call.to_h

        # Ensure arguments is a string in hash format too
        if normalized.dig(:function, :arguments)
          args = normalized[:function][:arguments]
          normalized[:function][:arguments] = args.is_a?(Hash) ? args.to_json : args.to_s
        end

        normalized
      end
    end
  end
end
