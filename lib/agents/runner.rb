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
            callbacks: {}, chat: nil)
      chat_contexts = {}
      current_agent = starting_agent
      context_wrapper = RunContext.new(deep_copy_context(context), callbacks: callbacks)
      context_wrapper.context[:current_agent] = current_agent.name
      manager = context_wrapper.callback_manager
      manager.emit_run_start(current_agent.name, input, context_wrapper)
      runtime_headers = Helpers::HashNormalizer.normalize(headers, label: "headers")
      runtime_params = Helpers::HashNormalizer.normalize(params, label: "params")
      request_options = { headers: runtime_headers, params: runtime_params }

      supplied_chat = chat
      chat ||= current_agent.build_chat(context_wrapper)
      prepare_chat(chat, current_agent, context_wrapper, runtime_headers, runtime_params, chat_contexts)
      restore_conversation_history(chat, context_wrapper) unless supplied_chat
      manager.emit_chat_created(chat, current_agent.name, chat.model.id, context_wrapper, chat.temperature)
      chat.ask_later(input) if input && !last_message_matches?(chat, input)
      turns = 0

      # Keep model calls and tool rounds separate so handoffs and limits have a
      # boundary outside RubyLLM's automatic loop.
      # https://rubyllm.com/next/agentic-workflows/#driving-the-loop-yourself
      loop do
        chat.run_tools
        # A handoff must wait until every call in the old agent's round is settled.
        break if chat.awaiting_approval?

        if (handoff = context_wrapper.context[:pending_handoff])
          target_name = handoff[:target_agent] || handoff["target_agent"]
          next_agent = registry[target_name]
          raise AgentNotFoundError, "Handoff failed: Agent '#{target_name}' not found in registry" unless next_agent

          context_wrapper.context[:conversation_history] =
            Helpers::MessageExtractor.extract_messages(chat, current_agent)
          context_wrapper.context[:current_agent] = next_agent.name
          begin
            # New native configuration prevents provider options leaking across agents.
            next_chat = next_agent.build_chat(context_wrapper)
            chat.messages.reject { |message| message.role == :system }.each { |message| next_chat.add_message(message) }
            prepare_chat(next_chat, next_agent, context_wrapper, runtime_headers, runtime_params, chat_contexts)
          rescue StandardError
            context_wrapper.context[:current_agent] = current_agent.name
            raise
          end

          manager.emit_agent_complete(current_agent.name, nil, nil, context_wrapper)
          manager.emit_agent_handoff(current_agent.name, next_agent.name, "handoff", context_wrapper)
          current_agent = next_agent
          chat = next_chat
          context_wrapper.context.delete(:pending_handoff)
          manager.emit_chat_created(chat, current_agent.name, chat.model.id, context_wrapper, chat.temperature)
        end
        break if chat.complete?

        raise MaxTurnsExceeded, "Exceeded maximum turns: #{max_turns}" if turns >= max_turns

        turns += 1
        manager.emit_agent_thinking(current_agent.name, turns == 1 ? input : "(continuing conversation)",
                                    context_wrapper)
        response = chat.generate
        Helpers::MessageExtractor.assign_agent_name(response, current_agent.name)
        manager.emit_llm_call_complete(current_agent.name, chat.model.id, response, context_wrapper)
      end

      response = chat.messages.reverse.find { |message| message.role == :assistant }
      output = if response && !chat.awaiting_approval?
                 chat.schema ? response.parsed : response.content
               end
      finalize_run(chat, context_wrapper, current_agent, output: output, request_options: request_options)
    rescue MaxTurnsExceeded => e
      finalize_run(chat, context_wrapper, current_agent, output: "Conversation ended: #{e.message}", error: e,
                                                         request_options: request_options)
    rescue StandardError => e
      finalize_run(chat, context_wrapper, current_agent, output: nil, error: e, request_options: request_options)
    ensure
      chat_contexts.each { |instrumented_chat, original| instrumented_chat.with_context(original) }
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
    def finalize_run(chat, context_wrapper, current_agent, output:, error: nil, request_options: nil)
      save_conversation_state(chat, context_wrapper, current_agent) if chat

      result = RunResult.new(
        output: output,
        messages: chat ? Helpers::MessageExtractor.extract_messages(chat, current_agent) : [],
        usage: context_wrapper.usage,
        error: error,
        context: context_wrapper.context,
        chat: chat,
        request_options: request_options
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
      context = context.transform_keys(&:to_sym)
      # Handle deep copying for thread safety
      context.dup.tap do |copied|
        copied[:conversation_history] = context[:conversation_history]&.map(&:dup) || []
        # Don't copy agents - they're immutable
        copied[:current_agent] = context[:current_agent]
        copied[:turn_count] = context[:turn_count] || 0
      end
    end

    def restore_conversation_history(chat, context_wrapper)
      valid_tool_call_ids = Set.new
      context_wrapper.context[:conversation_history].each do |attributes|
        next if (attributes[:role] || attributes["role"]).to_s == "system"

        message = Helpers::MessageExtractor.restore_message(attributes)
        if message.role == :tool && !valid_tool_call_ids.include?(message.tool_call_id)
          Agents.logger&.warn("Skipping tool message without matching assistant tool_call_id #{message.tool_call_id}")
          next
        end

        chat.add_message(message)
        valid_tool_call_ids.merge(message.tool_calls.keys) if message.tool_call?
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

    def prepare_chat(chat, agent, context_wrapper, runtime_headers, runtime_params, chat_contexts)
      chat_contexts[chat] = chat.context
      config = (chat.context&.config || RubyLLM.config).dup
      config.instrumenter = NativeInstrumenter.new(context_wrapper, config.instrumenter)
      chat.with_context(RubyLLM::Context.new(config))
      chat.with_headers(Helpers::HashNormalizer.merge(chat.headers, runtime_headers))
      chat.with_provider_options(Helpers::HashNormalizer.merge(chat.provider_options, runtime_params))

      tools = (chat.tools.values + agent.all_tools).map do |tool|
        tool = tool.new if tool.is_a?(Class)
        tool = tool.tool if tool.is_a?(ToolWrapper)
        tool.is_a?(Tool) ? ToolWrapper.new(tool, context_wrapper) : tool
      end
      chat.with_tools(nil).with_tools(*tools)
      # Application state and first-handoff selection require sequential tools.
      chat.with_tool_options(concurrency: false)
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
  end
end
