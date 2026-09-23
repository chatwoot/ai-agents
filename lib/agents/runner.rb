# frozen_string_literal: true

require "set"

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
    # @param params [Hash, nil] Provider-specific parameters passed to the underlying LLM (e.g., service_tier)
    # @param callbacks [Hash] Optional callbacks for real-time event notifications
    # @return [RunResult] The result containing output, messages, and usage
    def run(starting_agent, input, context: {}, registry: {}, max_turns: DEFAULT_MAX_TURNS, headers: nil, params: nil,
            callbacks: {})
      # The starting_agent is already determined by AgentRunner based on conversation history
      current_agent = starting_agent

      # Create context wrapper with deep copy for thread safety
      context_copy = deep_copy_context(context)
      context_wrapper = RunContext.new(context_copy, callbacks: callbacks)
      current_turn = 0

      # Emit run start event
      context_wrapper.callback_manager.emit_run_start(current_agent.name, input, context_wrapper)

      runtime_headers = Helpers::HashNormalizer.normalize(headers, label: "headers")
      agent_headers = Helpers::HashNormalizer.normalize(current_agent.headers, label: "headers")
      runtime_params = Helpers::HashNormalizer.normalize(params, label: "params")
      agent_params = Helpers::HashNormalizer.normalize(current_agent.params, label: "params")

      # Create chat and restore conversation history
      chat = build_chat(current_agent)
      current_headers = Helpers::HashNormalizer.merge(agent_headers, runtime_headers)
      current_params = Helpers::HashNormalizer.merge(agent_params, runtime_params)
      apply_headers(chat, current_headers)
      apply_params(chat, current_params)
      configure_chat_for_agent(chat, current_agent, context_wrapper, replace: false)
      restore_conversation_history(chat, context_wrapper)
      input_already_in_history = last_message_matches?(chat, input)
      unless input_already_in_history
        content, attachments = build_content(input)
        chat.ask_later(content, with: attachments)
      end
      context_wrapper.callback_manager.emit_chat_created(
        chat, current_agent.name, current_agent.model, context_wrapper, current_agent.temperature,
        current_agent.protocol, current_agent.thinking
      )

      loop do
        current_turn += 1
        raise MaxTurnsExceeded, "Exceeded maximum turns: #{max_turns}" if current_turn > max_turns

        # One provider request per turn. Run tools separately so handoffs stop before another request.
        message_count_before_response = chat_message_count(chat)
        thinking_input = current_turn == 1 ? input : "(continuing conversation)"
        context_wrapper.callback_manager.emit_agent_thinking(current_agent.name, thinking_input, context_wrapper)
        response = chat.generate
        assign_agent_name_to_new_assistant_messages(chat, current_agent, message_count_before_response)
        track_usage(response, context_wrapper)

        # Emit LLM call complete event with model and response for instrumentation
        context_wrapper.callback_manager.emit_llm_call_complete(
          current_agent.name, current_agent.model, response, context_wrapper
        )

        chat.run_tools if response.tool_call?

        if context_wrapper.context[:pending_handoff]
          handoff_info = context_wrapper.context.delete(:pending_handoff)
          next_agent = handoff_info[:target_agent]

          # Validate that the target agent is in our registry
          # This prevents handoffs to agents that weren't explicitly provided
          unless registry[next_agent.name]
            error = AgentNotFoundError.new("Handoff failed: Agent '#{next_agent.name}' not found in registry")
            return finalize_run(chat, context_wrapper, current_agent, output: nil, error: error)
          end

          # Save current conversation state before switching
          save_conversation_state(chat, context_wrapper, current_agent)

          # Emit agent complete event before handoff
          context_wrapper.callback_manager.emit_agent_complete(current_agent.name, nil, nil, context_wrapper)

          # Emit agent handoff event
          context_wrapper.callback_manager.emit_agent_handoff(current_agent.name, next_agent.name, "handoff",
                                                              context_wrapper)

          # Switch to new agent - store agent name for persistence
          current_agent = next_agent
          context_wrapper.context[:current_agent] = next_agent.name

          # A fresh chat prevents protocol and thinking settings leaking across agents.
          next_chat = build_chat(current_agent)
          next_chat.messages = chat.messages
          chat = next_chat
          configure_chat_for_agent(chat, current_agent, context_wrapper, replace: false)
          agent_headers = Helpers::HashNormalizer.normalize(current_agent.headers, label: "headers")
          current_headers = Helpers::HashNormalizer.merge(agent_headers, runtime_headers)
          chat.with_headers(current_headers)
          agent_params = Helpers::HashNormalizer.normalize(current_agent.params, label: "params")
          current_params = Helpers::HashNormalizer.merge(agent_params, runtime_params)
          chat.with_provider_options(current_params)
          context_wrapper.callback_manager.emit_chat_created(
            chat, current_agent.name, current_agent.model, context_wrapper, current_agent.temperature,
            current_agent.protocol, current_agent.thinking
          )

          # Force the new agent to respond to the conversation context
          # This ensures the user gets a response from the new agent
          input = nil
          next
        end

        # A tool result needs another provider request under the turn limit.
        next if response.tool_call?

        # If no tools were called, we have our final response
        output = current_agent.response_schema ? response.parsed : response.content
        return finalize_run(chat, context_wrapper, current_agent, output: output)
      end
    rescue MaxTurnsExceeded => e
      finalize_run(chat, context_wrapper, current_agent,
                   output: "Conversation ended: #{e.message}", error: e)
    rescue StandardError => e
      finalize_run(chat, context_wrapper, current_agent, output: nil, error: e)
    end

    private

    def build_chat(agent)
      RubyLLM::Chat.new(model: agent.model, provider: agent.provider, protocol: agent.protocol,
                        assume_model_exists: agent.assume_model_exists)
    end

    # Saves conversation state, builds a RunResult, emits completion callbacks, and returns it.
    # Centralises the finalize-and-return pattern used by the normal path and error rescues.
    #
    # @param chat [RubyLLM::Chat, nil] The chat instance (nil in early-failure rescues)
    # @param context_wrapper [RunContext] Context wrapper for state and callbacks
    # @param current_agent [Agents::Agent] The currently active agent
    # @param output [String, nil] The output text for the result
    # @param error [StandardError, nil] Optional error to attach to the result
    # @return [RunResult]
    def finalize_run(chat, context_wrapper, current_agent, output:, error: nil)
      save_conversation_state(chat, context_wrapper, current_agent) if chat

      result = RunResult.new(
        output: output,
        messages: chat ? Helpers::MessageExtractor.extract_messages(chat, current_agent) : [],
        usage: context_wrapper.usage,
        error: error,
        context: context_wrapper.context
      )

      context_wrapper.callback_manager.emit_agent_complete(current_agent.name, result, error, context_wrapper)
      context_wrapper.callback_manager.emit_run_complete(current_agent.name, result, context_wrapper)

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
    # Supports user, assistant, and tool role messages for complete conversation continuity.
    #
    # @param chat [RubyLLM::Chat] The chat instance to restore history into
    # @param context_wrapper [RunContext] Context containing conversation history
    def restore_conversation_history(chat, context_wrapper)
      history = context_wrapper.context[:conversation_history] || []
      valid_tool_call_ids = Set.new

      history.each_with_index do |msg, index|
        msg = with_completed_tool_calls(history, index, msg)
        next unless restorable_message?(msg)

        if msg[:role].to_sym == :tool &&
           msg[:tool_call_id] &&
           !valid_tool_call_ids.include?(msg[:tool_call_id])
          Agents.logger&.warn("Skipping tool message without matching assistant tool_call_id #{msg[:tool_call_id]}")
          next
        end

        message_params = build_message_params(msg)
        next unless message_params # Skip invalid messages

        message = RubyLLM::Message.new(**message_params)
        assign_restored_agent_name(message, msg)
        chat.add_message(message)

        if message.role == :assistant && message_params[:tool_calls]
          valid_tool_call_ids.merge(message_params[:tool_calls].keys)
        end
      end
    end

    def with_completed_tool_calls(history, index, msg)
      return msg unless msg[:role].to_sym == :assistant && msg[:tool_calls]&.any?

      msg.merge(tool_calls: completed_tool_calls(history, index, msg[:tool_calls]))
    end

    def completed_tool_calls(history, index, tool_calls)
      following_results = history[(index + 1)..].take_while { |entry| entry[:role].to_sym == :tool }
      following_ids = following_results.map { |entry| entry[:tool_call_id] }.to_set
      tool_calls.select { |call| following_ids.include?(call[:id] || call["id"]) }
    end

    # Check if a message should be restored
    def restorable_message?(msg)
      role = msg[:role].to_sym
      return false unless %i[user assistant tool].include?(role)

      # Allow assistant messages that only contain tool calls (no text content)
      assistant_payload = role == :assistant && (msg[:tool_calls]&.any? || msg[:thinking_signature])
      return false if role != :tool && !assistant_payload && Helpers::MessageExtractor.content_empty?(msg[:content])

      true
    end

    # Build message parameters for restoration
    def build_message_params(msg)
      role = msg[:role].to_sym

      content_value = msg[:content]
      # Assistant tool-call messages may have empty text, but still need placeholder content
      content_value = "" if content_value.nil? && role == :assistant && msg[:tool_calls]&.any?

      content, attachments = build_content(content_value)
      params = { role: role, content: content }
      params[:attachments] = attachments if attachments.any?
      if role == :assistant && msg[:thinking_signature]
        params[:thinking] = { text: msg[:thinking], signature: msg[:thinking_signature] }
      end

      # Handle tool-specific parameters (Tool Results)
      if role == :tool
        return nil unless valid_tool_message?(msg)

        params[:tool_call_id] = msg[:tool_call_id]
      end

      # FIX: Restore tool_calls on assistant messages
      # This is required by OpenAI/Anthropic API contracts to link
      # subsequent tool result messages back to this request.
      if role == :assistant && msg[:tool_calls] && !msg[:tool_calls].empty?
        # Convert stored array of hashes back into the Hash format RubyLLM expects
        # RubyLLM stores tool_calls as: { call_id => ToolCall_object, ... }
        # Reference: openai/tools.rb:35 uses hash iteration |_, tc|
        params[:tool_calls] = msg[:tool_calls].each_with_object({}) do |tc, hash|
          tool_call_id = tc[:id] || tc["id"]
          next unless tool_call_id

          hash[tool_call_id] = RubyLLM::ToolCall.new(
            id: tool_call_id,
            name: tc[:name] || tc["name"],
            arguments: tc[:arguments] || tc["arguments"] || {},
            thought_signature: tc[:thought_signature] || tc["thought_signature"]
          )
        end
      end

      params
    end

    # Split stored content into RubyLLM 2 text and attachments.
    # Multimodal arrays follow the OpenAI content format: [{type: 'text', text: '...'}, {type: 'image_url', ...}]
    def build_content(content_value)
      return [content_value.to_json, []] if content_value.is_a?(Hash)
      return [content_value, []] unless content_value.is_a?(Array)

      text_parts = content_value.filter_map { |p| p[:text] || p["text"] if (p[:type] || p["type"]) == "text" }
      image_urls = content_value.filter_map do |p|
        next unless (p[:type] || p["type"]) == "image_url"

        p.dig(:image_url, :url) || p.dig("image_url", "url")
      end

      return [content_value.to_json, []] if text_parts.empty? && image_urls.empty?

      [text_parts.join(" "), image_urls]
    end

    # Validate tool message has required tool_call_id
    def valid_tool_message?(msg)
      if msg[:tool_call_id]
        true
      else
        Agents.logger&.warn("Skipping tool message without tool_call_id in conversation history")
        false
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

    def assign_agent_name_to_new_assistant_messages(chat, current_agent, start_index)
      # Runtime chats are RubyLLM::Chat instances and expose messages. Keep this
      # no-op guard for chat-like doubles/adapters that do not expose history.
      return unless chat.respond_to?(:messages)

      chat.messages[start_index..]&.each do |message|
        next unless message.role == :assistant

        Helpers::MessageExtractor.assign_agent_name(message, current_agent.name)
      end
    end

    def chat_message_count(chat)
      # Runtime chats are RubyLLM::Chat instances and expose messages. Keep this
      # fallback for chat-like doubles/adapters where attribution is irrelevant.
      return 0 unless chat.respond_to?(:messages)

      chat.messages.length
    end

    def assign_restored_agent_name(message, msg)
      return unless message.role == :assistant

      restored_agent_name = msg[:agent_name] || msg["agent_name"]
      Helpers::MessageExtractor.assign_agent_name(message, restored_agent_name)
    end

    # Configures a RubyLLM chat instance with agent-specific settings.
    # Swaps agent settings while preserving conversation history during handoffs.
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
      if replace
        chat.with_model(
          agent.model,
          provider: agent.provider,
          protocol: agent.protocol,
          assume_model_exists: agent.assume_model_exists
        )
      end

      # Configure chat with instructions, temperature, tools, and schema
      chat.with_instructions(system_prompt)
      chat.with_temperature(agent.temperature)
      chat.with_thinking(**agent.thinking) if agent.thinking
      chat.with_tools(nil) if replace
      chat.with_tools(*all_tools)
      chat.with_schema(agent.response_schema)

      chat
    end

    # Check if the last message in the chat already matches the user's input.
    # This happens when an external system (e.g. Chatwoot) includes the current
    # user message in the conversation history passed via context.
    #
    # TODO: This .to_s == .to_s comparison is a best-effort safety net and is
    # brittle for edge cases (trailing whitespace, Hash/JSON round-tripping).
    # The proper fix is for callers to pass nil when input is already present
    # in conversation history, similar to the handoff continuation path.
    def last_message_matches?(chat, input)
      return false unless input && chat.respond_to?(:messages)

      last_msg = chat.messages.last
      return false unless last_msg&.role == :user

      content, attachments = build_content(input)
      last_msg.content == content && last_msg.attachments.map { |attachment| attachment.source.to_s } == attachments
    end

    def apply_headers(chat, headers)
      return if headers.empty?

      chat.with_headers(headers)
    end

    def apply_params(chat, params)
      return if params.empty?

      chat.with_provider_options(params)
    end

    def track_usage(response, context_wrapper)
      return unless context_wrapper&.usage

      context_wrapper.usage.add(response)
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
