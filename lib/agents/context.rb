# frozen_string_literal: true

module Agents
  # Shared state between agents and tools that persists across handoffs
  #
  # @example Use context in tools
  #   class UpdateSeatTool < Agents::ToolBase
  #     def perform(confirmation_number:, new_seat:, context:)
  #       context[:confirmation_number] = confirmation_number
  #       context[:seat_number] = new_seat
  #       "Updated seat to #{new_seat}"
  #     end
  #   end
  class Context
    # Initialize a new context
    def initialize(initial_data = {})
      @data = initial_data.is_a?(Hash) ? initial_data.dup : {}
      @metadata = {
        created_at: Time.now,
        updated_at: Time.now,
        agent_history: []
      }
    end

    # Get a value from the context
    def [](key)
      @data[key.to_sym]
    end

    # Set a value in the context
    def []=(key, value)
      @data[key.to_sym] = value
      @metadata[:updated_at] = Time.now
    end

    # Get all context data
    def to_h
      @data.dup
    end

    # Update multiple values at once
    def update(hash)
      return unless hash.is_a?(Hash)
      hash.each { |key, value| self[key] = value }
    end

    # Check if a key exists
    def key?(key)
      @data.key?(key.to_sym)
    end

    # Deep access to nested data
    def dig(*keys)
      @data.dig(*keys.map(&:to_sym))
    end

    # Check if context has any data
    def any?
      @data.any?
    end

    # Record agent transition in metadata
    def record_agent_transition(from_agent, to_agent, reason = nil)
      @metadata[:agent_history] << {
        from: from_agent,
        to: to_agent,
        reason: reason,
        timestamp: Time.now
      }
      @metadata[:updated_at] = Time.now
    end

    # Get agent transition history
    def agent_transitions
      @metadata[:agent_history].dup
    end

    # Clear agent transition history
    def clear_transitions
      @metadata[:agent_history].clear
      @metadata[:updated_at] = Time.now
    end

    # String representation
    def inspect
      "#<#{self.class.name} data=#{@data.inspect}>"
    end
  end
end
