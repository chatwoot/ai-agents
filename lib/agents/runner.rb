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
      current_agent = starting_agent
      context_wrapper = RunContext.new(deep_copy_context(context), callbacks: callbacks)
      context_wrapper.context[:current_agent] = current_agent.name
      manager = context_wrapper.callback_manager
      manager.emit_run_start(current_agent.name, input, context_wrapper)
      runtime_headers = Helpers::HashNormalizer.normalize(headers, label: "headers")
      runtime_params = Helpers::HashNormalizer.normalize(params, label: "params")

      chat = RubyLLM.chat(model: current_agent.model, provider: current_agent.provider,
                          assume_model_exists: current_agent.assume_model_exists)
      configure_chat_for_agent(chat, current_agent, context_wrapper)
      apply_request_options(chat, current_agent, runtime_headers, runtime_params)
      restore_conversation_history(chat, context_wrapper)
      manager.emit_chat_created(chat, current_agent.name, current_agent.model, context_wrapper,
                                current_agent.temperature)
      chat.ask_later(input) if input && !last_message_matches?(chat, input)
      turns = 0

      # Keep model calls and tool rounds separate so handoffs and limits have a
      # boundary outside RubyLLM's automatic loop.
      # https://rubyllm.com/next/agentic-workflows/#driving-the-loop-yourself
      loop do
        chat.run_tools
        # A handoff must wait until every call in the old agent's round is settled.
        break if chat.awaiting_approval?

        if (handoff = context_wrapper.context.delete(:pending_handoff))
          next_agent = registry[handoff[:target_agent]]
          unless next_agent
            raise AgentNotFoundError, "Handoff failed: Agent '#{handoff[:target_agent]}' not found in registry"
          end

          context_wrapper.context[:conversation_history] =
            Helpers::MessageExtractor.extract_messages(chat, current_agent)
          manager.emit_agent_complete(current_agent.name, nil, nil, context_wrapper)
          manager.emit_agent_handoff(current_agent.name, next_agent.name, "handoff", context_wrapper)
          current_agent = next_agent
          context_wrapper.context[:current_agent] = current_agent.name
          configure_chat_for_agent(chat, current_agent, context_wrapper, replace: true)
          apply_request_options(chat, current_agent, runtime_headers, runtime_params)
          manager.emit_chat_created(chat, current_agent.name, current_agent.model, context_wrapper,
                                    current_agent.temperature)
        end
        break if chat.complete?

        raise MaxTurnsExceeded, "Exceeded maximum turns: #{max_turns}" if turns >= max_turns

        turns += 1
        manager.emit_agent_thinking(current_agent.name, turns == 1 ? input : "(continuing conversation)",
                                    context_wrapper)
        response = chat.generate
        Helpers::MessageExtractor.assign_agent_name(response, current_agent.name)
        track_usage(response, context_wrapper)
        manager.emit_llm_call_complete(current_agent.name, current_agent.model, response, context_wrapper)
      end

      response = chat.messages.reverse.find { |message| message.role == :assistant }
      output = if response && !chat.awaiting_approval?
                 current_agent.response_schema ? response.parsed : response.content
               end
      finalize_run(chat, context_wrapper, current_agent, output: output)
    rescue MaxTurnsExceeded => e
      finalize_run(chat, context_wrapper, current_agent, output: "Conversation ended: #{e.message}", error: e)
    rescue StandardError => e
      finalize_run(chat, context_wrapper, current_agent, output: nil, error: e)
    end

    private

    # Saves conversation state, builds a RunResult, emits completion callbacks, and returns it.
    # Used by successful runs, approval pauses, and error rescues.
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
        context: context_wrapper.context,
        chat: chat
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

      history.each do |msg|
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

    # Check if a message should be restored
    def restorable_message?(msg)
      role = msg[:role].to_sym
      return false unless %i[user assistant tool].include?(role)

      # Allow assistant messages that only contain tool calls (no text content)
      tool_calls_present = role == :assistant && msg[:tool_calls] && !msg[:tool_calls].empty?
      return false if role != :tool && !tool_calls_present &&
                      Helpers::MessageExtractor.content_empty?(msg[:content])

      true
    end

    # Build message parameters for restoration
    def build_message_params(msg)
      role = msg[:role].to_sym

      content_value = msg[:content]
      # Assistant tool-call messages may have empty text, but still need placeholder content
      content_value = "" if content_value.nil? && role == :assistant && msg[:tool_calls]&.any?

      params = {
        role: role,
        **build_content(content_value)
      }

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
            arguments: tc[:arguments] || tc["arguments"] || {}
          )
        end
      end

      params
    end

    # Convert legacy multimodal content to v2's separate content and attachments.
    # Multimodal arrays follow the OpenAI content format: [{type: 'text', text: '...'}, {type: 'image_url', ...}]
    def build_content(content_value)
      return { content: content_value.to_json } if content_value.is_a?(Hash)
      return { content: content_value } unless content_value.is_a?(Array)

      parts = content_value.map { |part| part.transform_keys(&:to_sym) }
      text = parts.filter_map { |part| part[:text] if part[:type] == "text" }.join(" ")
      attachments = parts.filter_map do |part|
        image = part[:image_url]
        image[:url] || image["url"] if part[:type] == "image_url" && image
      end
      { content: text, attachments: attachments }
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
    end

    def assign_restored_agent_name(message, msg)
      return unless message.role == :assistant

      restored_agent_name = msg[:agent_name] || msg["agent_name"]
      Helpers::MessageExtractor.assign_agent_name(message, restored_agent_name)
    end

    # Configures a RubyLLM chat instance with agent-specific settings.
    # Replaces settings explicitly while preserving conversation history during handoffs.
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
          assume_model_exists: agent.assume_model_exists
        )
      end

      # Configure chat with instructions, temperature, tools, and schema
      chat.with_instructions(system_prompt)
      chat.with_temperature(agent.temperature)
      chat.with_tools(nil).with_tools(*all_tools)
      # Shared application state and handoff selection are sequential within a run.
      chat.with_tool_options(concurrency: false)
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
      last_msg && last_msg.role == :user && last_msg.content.to_s == input.to_s
    end

    def apply_request_options(chat, agent, runtime_headers, runtime_params)
      chat.with_headers(Helpers::HashNormalizer.merge(agent.headers, runtime_headers))
      chat.with_provider_options(Helpers::HashNormalizer.merge(agent.params, runtime_params))
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
