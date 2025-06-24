# frozen_string_literal: true

# Tool base class - enables agents to perform actions and interact with external systems
# Tools are the primary way agents accomplish tasks beyond conversation. They receive
# the current execution context automatically, allowing them to read/write shared state,
# access conversation history, and signal handoffs to other agents. Tools use a Ruby-friendly
# DSL for parameter definition and integrate seamlessly with the LLM's function calling.

# Slim wrapper around RubyLLM::Tool with Ruby-like parameter syntax and context support.
# All tools are context-aware by default and receive the current execution context.
#
# @example Define a simple tool (context optional)
#   class WeatherTool < Agents::Tool
#     description "Get current weather for a city"
#     param :city, String, "City name"
#
#     def call(city:, context: nil)
#       "The weather in #{city} is sunny"
#     end
#   end
#
# @example Define a context-using tool
#   class UpdateSeatTool < Agents::Tool
#     description "Update passenger seat"
#     param :confirmation_number, String, "Confirmation number"
#     param :new_seat, String, "New seat number"
#
#     def call(confirmation_number:, new_seat:, context:)
#       context[:confirmation_number] = confirmation_number
#       context[:seat_number] = new_seat
#       "Updated seat to #{new_seat}"
#     end
#   end
module Agents
  class Tool < RubyLLM::Tool
    class << self
      # Enhanced parameter definition with Ruby type classes
      # @param name [Symbol] The parameter name
      # @param type [Class, String] Ruby class (String, Integer) or JSON type string
      # @param desc [String] Description of the parameter
      # @param required [Boolean] Whether the parameter is required
      def param(name, type = String, desc = nil, required: true, **options)
        # Convert Ruby types to JSON schema types
        json_type = case type
                    when String, "string" then "string"
                    when Integer, "integer" then "integer"
                    when Float, "number" then "number"
                    when TrueClass, FalseClass, "boolean" then "boolean"
                    when Array, "array" then "array"
                    when Hash, "object" then "object"
                    else "string"
                    end

        # Call parent param method
        super(name, type: json_type, desc: desc, required: required, **options)
      end
    end

    # Set the execution context for this tool instance
    # @param context [Agents::Context] The execution context
    def set_context(context)
      @execution_context = context
    end

    # Override execute to always inject context
    # This is called by RubyLLM's base Tool#call method
    # @param args [Hash] Tool arguments
    # @return [Object] Tool result
    def execute(**args)
      # Always pass context to tools, they can choose to use it or ignore it
      perform(context: @execution_context, **args)
    end

    # Default implementation - subclasses should override this
    # @param args [Hash] Tool arguments including context
    # @return [Object] Tool result
    def perform(**args)
      raise NotImplementedError, "Tools must implement #perform method"
    end

    # Support for proc-like behavior and [] syntax
    def to_proc
      method(:execute).to_proc
    end

    alias [] execute
  end
end
