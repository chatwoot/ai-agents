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
        json_type = if [String, "string"].include?(type)
                      "string"
                    elsif [Integer, "integer"].include?(type)
                      "integer"
                    elsif [Float, "number"].include?(type)
                      "number"
                    elsif [TrueClass, FalseClass, "boolean"].include?(type)
                      "boolean"
                    elsif [Array, "array"].include?(type)
                      "array"
                    elsif [Hash, "object"].include?(type)
                      "object"
                    else
                      "string"
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
      # Wrap tool execution in a span
      Agents::Tracing.with_span(
        name: "Tool:#{self.class.name}",
        category: :tool,
        metadata: tool_span_metadata(args)
      ) do
        # Always pass context to tools, they can choose to use it or ignore it
        perform(context: @execution_context, **args)
      end
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

    private

    # Generate metadata for tool span
    # @param args [Hash] Tool arguments
    # @return [Hash] Tool span metadata
    def tool_span_metadata(args)
      metadata = {
        tool_name: self.class.name,
        tool_type: "local",
        args_count: args.keys.length
      }

      # Include arguments if sensitive data is allowed
      if Agents.configuration.respond_to?(:tracing) &&
         Agents.configuration.tracing.respond_to?(:include_sensitive_data) &&
         Agents.configuration.tracing.include_sensitive_data

        # Filter out context from args for logging
        safe_args = args.reject { |k, _| k == :context }
        metadata[:args] = truncate_tool_args(safe_args)
      end

      metadata
    end

    # Truncate tool arguments for storage
    # @param args [Hash] Tool arguments
    # @return [Hash] Truncated arguments
    def truncate_tool_args(args)
      args.transform_values do |value|
        case value
        when String
          value.length > 200 ? "#{value[0...200]}... [truncated]" : value
        when Hash, Array
          value.inspect.length > 200 ? "#{value.inspect[0...200]}... [truncated]" : value
        else
          value
        end
      end
    end
  end
end
