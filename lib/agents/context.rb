# frozen_string_literal: true

# Context wrapper that provides shared state between agents and tools.
# Similar to Python's RunContextWrapper, this allows tools to access and modify
# shared context that persists across agent handoffs.
#
# @example Define a custom context
#   class AirlineContext < Agents::Context
#     attr_accessor :passenger_name, :confirmation_number, :seat_number, :flight_number
#
#     def initialize
#       super
#       @passenger_name = nil
#       @confirmation_number = nil
#       @seat_number = nil
#       @flight_number = nil
#     end
#   end
#
# @example Use context in tools
#   class UpdateSeatTool < Agents::Tool
#     description "Update seat for a passenger"
#     param :confirmation_number, String, "Confirmation number"
#     param :new_seat, String, "New seat number"
#
#     def execute(confirmation_number:, new_seat:, context:)
#       context.confirmation_number = confirmation_number
#       context.seat_number = new_seat
#       "Updated seat to #{new_seat}"
#     end
#   end
module Agents
  class Context
    attr_reader :data, :metadata

    # Initialize a new context
    # @param initial_data [Hash] Initial context data
    def initialize(initial_data = {})
      @data = initial_data.dup
      @metadata = {
        created_at: Time.now,
        updated_at: Time.now,
        agent_history: []
      }
    end

    # Get a value from the context
    # @param key [Symbol, String] The key to retrieve
    # @return [Object] The value
    def [](key)
      @data[key.to_sym]
    end

    # Set a value in the context
    # @param key [Symbol, String] The key to set
    # @param value [Object] The value to set
    def []=(key, value)
      @data[key.to_sym] = value
      @metadata[:updated_at] = Time.now
    end

    # Get all context data
    # @return [Hash] All context data
    def to_h
      @data.dup
    end

    # Update multiple values at once
    # @param hash_or_context [Hash, Agents::Context] Values to update
    def update(hash_or_context)
      case hash_or_context
      when Hash
        hash_or_context.each { |key, value| self[key] = value }
      when Agents::Context
        hash_or_context.to_h.each { |key, value| self[key] = value }
      else
        raise ArgumentError, "Expected Hash or Agents::Context, got #{hash_or_context.class}"
      end
    end

    # Check if a key exists
    # @param key [Symbol, String] The key to check
    # @return [Boolean] True if key exists
    def key?(key)
      @data.key?(key.to_sym)
    end

    # Get all keys
    # @return [Array<Symbol>] All keys
    def keys
      @data.keys
    end

    # Clear all data (but preserve metadata)
    def clear!
      @data.clear
      @metadata[:updated_at] = Time.now
    end

    # Record agent transition in metadata
    # @param from_agent [String] Source agent name
    # @param to_agent [String] Target agent name
    # @param reason [String] Reason for handoff
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
    # @return [Array<Hash>] Agent transition history
    def agent_transitions
      @metadata[:agent_history].dup
    end

    # Create a copy of this context
    # @return [Agents::Context] A new context with the same data
    def dup
      new_context = self.class.new(@data)
      new_context.instance_variable_set(:@metadata, @metadata.dup)
      new_context
    end

    # String representation
    # @return [String] String representation of context
    def inspect
      "#<#{self.class.name} data=#{@data.inspect} updated_at=#{@metadata[:updated_at]}>"
    end
  end
end
