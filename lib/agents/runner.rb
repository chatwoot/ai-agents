# frozen_string_literal: true

# Runner class - the orchestrator that manages multi-agent conversations and state
# This is the primary interface for SDK users. The Runner maintains conversation continuity
# across agent handoffs by preserving the complete history and shared context. When an agent
# signals a handoff, the Runner seamlessly transitions to the new agent while ensuring it has
# full visibility into previous interactions. The design allows for stateless agents while
# maintaining stateful conversations, with built-in loop detection to prevent infinite handoffs.
#
# This implementation uses an item-based tracking system where handoffs are recorded as tool
# calls and outputs, preventing conversation pollution and infinite loops.

module Agents
  # Runner orchestrates multi-agent conversations with automatic handoffs.
  # This is the main entry point for SDK users - they only need to call runner.process(message)
  # and handoffs happen transparently while maintaining conversation history.
  #
  # @example Basic usage
  #   runner = Runner.new(initial_agent: TriageAgent, context: AirlineContext.new)
  #   response = runner.process("I need to change my seat")
  #
  # @example Accessing conversation items
  #   runner.run_items.each do |item|
  #     puts "#{item.class}: #{item.to_input_item}"
  #   end
  class Runner
    # @return [Agent] The currently active agent
    attr_reader :current_agent

    # @return [Agents::Context] Shared context across all agents
    attr_reader :context

    # @return [Array<RunItem>] All items generated during the run
    attr_reader :run_items

    # Initialize a new runner
    # @param initial_agent [Class] The agent class to start with (e.g., TriageAgent)
    # @param context [Agents::Context] Shared context for the conversation
    def initialize(initial_agent:, context:)
      @initial_agent_class = initial_agent
      @context = context
      @run_items = []
      @current_agent = nil
    end

    # Process a user message through the agent system.
    # Automatically handles handoffs and maintains conversation history.
    #
    # @param user_message [String] The user's input
    # @return [String] The final agent response after all handoffs
    # @raise [RuntimeError] If maximum handoffs are exceeded
    def process(user_message)
      # Add user message as an item
      @run_items << UserMessageItem.new(content: user_message, agent: nil)

      # Start with initial agent if this is the first message, otherwise use current agent
      @current_agent ||= @initial_agent_class.new(context: @context)

      # Process through agent loop until no more handoffs
      final_response = nil
      max_handoffs = 10 # Prevent infinite loops
      handoff_count = 0

      loop do
        # Clear any pending handoffs from previous iterations
        @context[:pending_handoff] = nil

        # Build clean input for agent from run items
        agent_input = build_agent_input

        # Call agent with the prepared input array
        # The agent will detect that input is an array and handle it appropriately
        agent_response = @current_agent.call(agent_input)

        # Process any tool calls (including handoffs)
        if agent_response.has_tool_calls?
          process_tool_calls(agent_response.tool_calls)
          # Important: When there are tool calls, we DON'T add the content as an assistant message
          # This prevents conversation pollution from messages like "I've connected you with someone..."
        elsif agent_response.has_content?
          # Only add assistant message if there's NO tool calls
          # This matches Python's behavior where tool calls and content are mutually exclusive
          @run_items << AssistantMessageItem.new(
            content: agent_response.content,
            agent: @current_agent
          )
        end

        # Check for handoffs
        if agent_response.handoff?
          handoff_count += 1
          raise "Maximum handoffs (#{max_handoffs}) exceeded. Possible infinite loop." if handoff_count > max_handoffs

          handoff_result = agent_response.handoff_result
          target_class = handoff_result.target_agent_class

          # Record the handoff in context
          @context.record_agent_transition(
            @current_agent.class.name,
            target_class.name,
            handoff_result.reason
          )

          # Switch to new agent
          @current_agent = target_class.new(context: @context)

          # Continue loop to process with new agent
        else
          # No handoff, we have our final response
          final_response = agent_response.content
          break
        end
      end

      final_response
    end

    # Get a summary of the conversation suitable for display
    # @return [String] Formatted conversation summary
    def conversation_summary
      @run_items.map do |item|
        case item
        when UserMessageItem
          "[User]: #{item.content}"
        when AssistantMessageItem
          "[#{item.agent.class.name}]: #{item.content}"
        when ToolCallItem
          "[#{item.agent.class.name}]: Called tool '#{item.tool_name}'"
        when HandoffOutputItem
          "[System]: Handoff from #{item.source_agent.class.name} to #{item.target_agent}"
        when ToolOutputItem
          "[Tool Output]: #{item.output}"
        else
          "[#{item.class.name}]: #{item.inspect}"
        end
      end.join("\n")
    end

    private

    # Process tool calls from an agent response
    # @param tool_calls [Array<Hash>] Tool calls to process
    def process_tool_calls(tool_calls)
      tool_calls.each do |tool_call|
        # Create tool call item
        tool_call_item = ToolCallItem.new(
          tool_name: tool_call[:name],
          arguments: tool_call[:arguments] || {},
          call_id: tool_call[:id],
          agent: @current_agent
        )
        @run_items << tool_call_item

        # Handle the result if it's already computed
        next unless tool_call[:result]

        result = tool_call[:result]

        # Check if this is a handoff
        if result.is_a?(Hash) && result[:type] == "handoff"
          # Create handoff output item
          handoff_output = HandoffOutputItem.new(
            tool_call_id: tool_call_item.call_id,
            output: result[:message],
            source_agent: @current_agent,
            target_agent: result[:target_class],
            agent: @current_agent
          )
          @run_items << handoff_output
        else
          # Regular tool output
          tool_output = ToolOutputItem.new(
            tool_call_id: tool_call_item.call_id,
            output: result,
            agent: @current_agent
          )
          @run_items << tool_output
        end
      end
    end

    # Build agent input from run items
    # @return [Array<Hash>] Input items formatted for agent consumption
    def build_agent_input
      # Convert run items to format expected by agents
      # This preserves tool calls and outputs in the conversation
      # Filter out nil items (handoff outputs return nil)
      @run_items.map(&:to_input_item).compact
    end
  end
end
