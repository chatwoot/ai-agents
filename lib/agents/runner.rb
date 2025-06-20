# frozen_string_literal: true

module Agents
  # Orchestrates multi-agent conversations with automatic handoffs
  class Runner
    attr_reader :current_agent, :context

    # Initialize a new runner
    def initialize(initial_agent:, context:)
      @initial_agent_class = initial_agent
      @context = context
      @current_agent = nil
    end

    # Process a user message through the agent system
    def process(user_message)
      # Start with initial agent if this is the first message
      @current_agent ||= @initial_agent_class.new(context: @context)

      # Process through agent loop until no more handoffs
      max_handoffs = 5 # Prevent infinite loops
      handoff_count = 0

      loop do
        # Clear any pending handoffs from previous iterations
        @context[:pending_handoff] = nil

        # Call current agent
        agent_response = @current_agent.call(user_message, context: @context)

        # Check for handoffs
        if agent_response.handoff?
          handoff_count += 1
          if handoff_count > max_handoffs
            raise ExecutionError, "Maximum handoffs (#{max_handoffs}) exceeded"
          end

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
          # No handoff, return final response
          return agent_response.content
        end
      end
    end
  end
end
