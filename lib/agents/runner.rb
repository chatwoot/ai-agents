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

      # Create initial chat
      chat = create_chat(current_agent, context_wrapper)

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

        # Check for handoff via context (set by HandoffTool)
        if context_wrapper.context[:pending_handoff]
          next_agent = context_wrapper.context[:pending_handoff]
          Agents.logger&.debug "[Agents] Handoff from #{current_agent.name} to #{next_agent.name}"

          # Switch to new agent
          current_agent = next_agent
          context_wrapper.context.delete(:pending_handoff)
          chat = create_chat(current_agent, context_wrapper)
          next
        end

        # If no tools were called, we have our final response
        unless response.tool_call?
          return RunResult.new(
            output: response.content,
            messages: extract_messages(chat),
            usage: context_wrapper.usage
          )
        end
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

    def create_chat(agent, context_wrapper)
      # Get system prompt (may be dynamic)
      system_prompt = agent.get_system_prompt(context_wrapper)

      # Wrap tools with context for thread-safe execution
      wrapped_tools = agent.all_tools.map do |tool|
        ToolWrapper.new(tool, context_wrapper)
      end

      # Create chat with proper RubyLLM API
      chat = RubyLLM.chat(model: agent.model)
      chat.with_instructions(system_prompt) if system_prompt
      chat.with_tools(*wrapped_tools) if wrapped_tools.any?
      chat
    end

    def extract_messages(chat)
      return [] unless chat.respond_to?(:messages)

      chat.messages.map do |msg|
        {
          role: msg.role,
          content: msg.content
        }.compact
      end
    end
  end
end
