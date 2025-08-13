# frozen_string_literal: true

module Agents
  # An immutable descriptor that represents a handoff request from one agent to another.
  # This is returned by HandoffTool instead of directly mutating state, ensuring thread safety
  # by allowing the Runner to handle all state changes atomically.
  #
  # The descriptor pattern ensures:
  # - Tools remain pure functions without side effects
  # - All state mutations happen in a single, controlled location (Runner)
  # - Thread safety is maintained without locks or synchronization
  # - Direct continuation without halt/restart cycles
  #
  # @example How it works in the handoff flow
  #   # 1. HandoffTool returns a descriptor (no mutations)
  #   descriptor = HandoffDescriptor.new(
  #     target_agent: billing_agent,
  #     message: "Transferring to billing..."
  #   )
  #
  #   # 2. Runner detects the descriptor and handles atomically
  #   if result.is_a?(HandoffDescriptor)
  #     reconfigure_chat_for_agent(chat, result.target_agent)
  #     # ... other atomic updates
  #   end
  #
  #   # 3. LLM continues naturally with the new agent context
  class HandoffDescriptor
    attr_reader :target_agent, :message

    # Create a new handoff descriptor
    #
    # @param target_agent [Agents::Agent] The agent to transfer the conversation to
    # @param message [String] The message to return to the LLM for natural continuation
    def initialize(target_agent:, message:)
      @target_agent = target_agent
      @message = message
      freeze # Ensure immutability
    end

    # String representation for cleaner logs and debugging
    def to_s
      @message
    end

    # Allows the descriptor to be used as a tool result
    # RubyLLM will use this for the tool response
    def to_str
      @message
    end
  end
end
