# frozen_string_literal: true

require "async"

module Agents
  # Runner orchestrates multi-agent conversations, handling the execution flow,
  # tool calls, handoffs between agents, and conversation state management.
  # It integrates with RubyLLM for LLM communication while adding agent-specific
  # capabilities like handoffs and context management.
  #
  # ## Key Responsibilities
  # 1. Managing conversation turns and enforcing turn limits
  # 2. Coordinating handoffs between agents
  # 3. Tracking token usage across all LLM calls
  # 4. Ensuring thread-safe context passing to tools
  #
  # ## RubyLLM Integration
  # The Runner works with our enhanced RubyLLM integration:
  # - Tools are wrapped with ContextualizedToolWrapper before passing to RubyLLM
  # - RubyLLM handles tool execution internally (we don't execute tools directly)
  # - Our monkey patch enables parallel tool execution when beneficial
  #
  # @example Running a simple agent
  #   result = Agents::Runner.run(
  #     my_agent,
  #     "What's the weather in NYC?",
  #     context: { user_id: 123 }
  #   )
  #   puts result.output
  #
  # @example Multi-agent conversation with handoffs
  #   result = Agents::Runner.run(
  #     support_agent,
  #     "I need help with my bill",
  #     context: { customer_id: 456 },
  #     max_turns: 20
  #   )
  class Runner
    DEFAULT_MAX_TURNS = 10

    class MaxTurnsExceeded < StandardError; end

    # Convenience class method for running agents
    def self.run(agent, input, context: {}, max_turns: DEFAULT_MAX_TURNS)
      new.run(agent, input, context: context, max_turns: max_turns)
    end

    # Execute an agent with the given input and context
    #
    # @param starting_agent [Agents::Agent] The initial agent to run
    # @param input [String] The user's input message
    # @param context [Hash] Shared context data accessible to all tools
    # @param max_turns [Integer] Maximum conversation turns before stopping
    # @return [RunResult] The result containing output, messages, and usage
    def run(starting_agent, input, context: {}, max_turns: DEFAULT_MAX_TURNS)
      current_agent = starting_agent
      context_wrapper = RunContext.new(context.dup)
      current_turn = 0

      # RubyLLM maintains conversation history internally
      # We just need to track the current conversation

      loop do
        current_turn += 1
        raise MaxTurnsExceeded, "Exceeded maximum turns: #{max_turns}" if current_turn > max_turns

        # Get system prompt (may be dynamic based on context)
        system_prompt = current_agent.get_system_prompt(context_wrapper)

        # Wrap tools with context before passing to RubyLLM
        contextualized_tools = prepare_tools(current_agent.all_tools, context_wrapper)

        # Create a new chat for this agent (RubyLLM handles message history)
        chat = create_chat(current_agent, system_prompt, contextualized_tools)

        # Add user input on first turn, otherwise continue conversation
        response = if current_turn == 1
                     chat.chat(input)
                   else
                     # For subsequent turns after handoff, we need to continue
                     # This is a simplified approach - in production you might
                     # want to maintain conversation history across handoffs
                     chat.complete
                   end

        # Update token usage
        context_wrapper.usage.add(response.usage) if response.respond_to?(:usage) && response.usage

        # Check for handoff signaled through context
        if (pending_handoff = context_wrapper.context[:pending_handoff])
          # Log the handoff for debugging
          Agents.logger&.debug "[Agents] Handoff from #{current_agent.name} to #{pending_handoff.name}"

          current_agent = pending_handoff
          context_wrapper.context.delete(:pending_handoff)

          # Continue with new agent
          next
        end

        # No handoff, return the result
        return RunResult.new(
          output: response.content,
          messages: extract_messages(chat),
          usage: context_wrapper.usage
        )
      end
    rescue MaxTurnsExceeded => e
      # Return partial result on max turns
      RunResult.new(
        output: "Conversation ended: #{e.message}",
        messages: [],
        usage: context_wrapper.usage,
        error: e
      )
    rescue StandardError => e
      # Return error result
      RunResult.new(
        output: nil,
        messages: [],
        usage: context_wrapper.usage,
        error: e
      )
    end

    private

    # Wrap each tool with context before passing to RubyLLM
    # This ensures thread-safe context injection without modifying RubyLLM internals
    def prepare_tools(tools, context_wrapper)
      tools.map { |tool| ContextualizedToolWrapper.new(tool, context_wrapper) }
    end

    # Create a RubyLLM chat instance with our wrapped tools
    def create_chat(agent, system_prompt, tools)
      RubyLLM.chat(
        model: agent.model,
        system: system_prompt,
        tools: tools
      )
    end

    # Extract message history from RubyLLM chat
    # Format may vary based on RubyLLM version
    def extract_messages(chat)
      return [] unless chat.respond_to?(:messages)

      chat.messages.map do |msg|
        {
          role: msg.role,
          content: msg.content
        }.tap do |h|
          h[:tool_calls] = msg.tool_calls if msg.respond_to?(:tool_calls) && msg.tool_calls
          h[:tool_call_id] = msg.tool_call_id if msg.respond_to?(:tool_call_id) && msg.tool_call_id
        end
      end
    end
  end

  # Represents the result of running an agent
  class RunResult
    attr_reader :output, :messages, :usage, :error

    def initialize(output:, messages:, usage:, error: nil)
      @output = output
      @messages = messages
      @usage = usage
      @error = error
    end

    def success?
      error.nil? && !output.nil?
    end

    def failed?
      !success?
    end
  end
end
