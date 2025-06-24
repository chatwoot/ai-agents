# frozen_string_literal: true

# Runner class - the orchestrator that manages multi-agent conversations and state
# This is the primary interface for SDK users. The Runner maintains conversation continuity
# across agent handoffs by preserving the complete history and shared context. When an agent
# signals a handoff, the Runner seamlessly transitions to the new agent while ensuring it has
# full visibility into previous interactions. The design allows for stateless agents while
# maintaining stateful conversations, with built-in loop detection to prevent infinite handoffs.

module Agents
  # Runner orchestrates multi-agent conversations with automatic handoffs
  # This is the main entry point for SDK users - they only need to call runner.process(message)
  # and handoffs happen transparently while maintaining conversation history.
  class Runner
    attr_reader :current_agent, :context, :conversation_history

    # Initialize a new runner
    # @param initial_agent [Class] The agent class to start with (e.g., TriageAgent)
    # @param context [Agents::Context] Shared context for the conversation
    def initialize(initial_agent:, context:)
      @initial_agent_class = initial_agent
      @context = context
      @conversation_history = []
      @current_agent = nil
    end

    # Process a user message through the agent system
    # Automatically handles handoffs and maintains conversation history
    # @param user_message [String] The user's input
    # @return [String] The final agent response after all handoffs
    def process(user_message)
      # Start trace for this workflow run
      Agents::Tracing.with_trace(workflow_name: determine_workflow_name, metadata: trace_metadata) do
        Agents::Tracing.with_span(name: "Runner:process", category: :runner,
                                  metadata: { user_message: user_message }) do
          process_with_tracing(user_message)
        end
      end
    end

    private

    # Internal process method with tracing context already established
    # @param user_message [String] The user's input
    # @return [String] The final agent response after all handoffs
    def process_with_tracing(user_message)
      # Add user message to conversation history
      @conversation_history << { role: "user", content: user_message, timestamp: Time.now }

      # Start with initial agent if this is the first message, otherwise use current agent
      @current_agent ||= @initial_agent_class.new(context: @context)

      # Process through agent loop until no more handoffs
      final_response = nil
      max_handoffs = 10 # Prevent infinite loops
      handoff_count = 0

      loop do
        # Clear any pending handoffs from previous iterations
        @context[:pending_handoff] = nil

        # Call current agent with conversation history
        agent_response = call_agent_with_history(@current_agent, user_message)

        # Add agent response to conversation history
        @conversation_history << {
          role: "assistant",
          content: agent_response.content,
          agent: @current_agent.class.name,
          timestamp: Time.now
        }

        # Check for handoffs
        if agent_response.handoff?
          handoff_count += 1
          raise "Maximum handoffs (#{max_handoffs}) exceeded. Possible infinite loop." if handoff_count > max_handoffs

          handoff_result = agent_response.handoff_result
          target_class = handoff_result.target_agent_class

          # Trace the handoff
          Agents::Tracing.with_span(
            name: "Handoff:#{@current_agent.class.name}→#{target_class.name}",
            category: :handoff,
            metadata: {
              from_agent: @current_agent.class.name,
              to_agent: target_class.name,
              reason: handoff_result.reason,
              handoff_count: handoff_count
            }
          ) do
            # Record the handoff in context
            @context.record_agent_transition(
              @current_agent.class.name,
              target_class.name,
              handoff_result.reason
            )

            # Switch to new agent
            @current_agent = target_class.new(context: @context)
          end

          # Continue loop to process with new agent
          # The new agent will automatically see the original user message in conversation history
        else
          # No handoff, we have our final response
          final_response = agent_response.content
          break
        end
      end

      final_response
    end

    # Determine workflow name for tracing
    # @return [String] Workflow name
    def determine_workflow_name
      "MultiAgentRunner"
    end

    # Generate trace metadata
    # @return [Hash] Trace metadata
    def trace_metadata
      {
        initial_agent: @initial_agent_class.name,
        conversation_turns: @conversation_history.length
      }
    end

    # Call an agent with the full conversation history
    # @param agent [Agents::Agent] The agent to call
    # @param current_message [String] The current user message
    # @return [Agents::AgentResponse] The agent's response
    def call_agent_with_history(agent, current_message)
      # Set the conversation history in the agent
      agent.instance_variable_set(:@conversation_history, format_conversation_for_agent)

      # Call the agent with the current message
      agent.call(current_message)
    end

    # Format conversation history for agent consumption
    # Converts our internal format to the format expected by Agent.call
    # @return [Array<Hash>] Formatted conversation history
    def format_conversation_for_agent
      formatted = []

      # Group conversations by user/assistant pairs
      @conversation_history.each_slice(2) do |user_msg, assistant_msg|
        next unless user_msg && assistant_msg

        formatted << {
          user: user_msg[:content],
          assistant: assistant_msg[:content],
          timestamp: user_msg[:timestamp]
        }
      end

      formatted
    end

    # Get the last user message from conversation history
    # Used when new agents need to process the original question
    # @return [String, nil] The last user message content
    def last_user_message
      @conversation_history.reverse.find { |msg| msg[:role] == "user" }&.dig(:content)
    end
  end
end
