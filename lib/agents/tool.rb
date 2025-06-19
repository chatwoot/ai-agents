# frozen_string_literal: true

# Enhanced tool class that extends RubyLLM::Tool with Ruby-like DSL features.
# Provides a more idiomatic Ruby interface while maintaining compatibility with RubyLLM.
#
# @example Define a simple tool
#   class WeatherTool < Agents::Tool
#     description "Get current weather for a city"
#     param :city, type: "string", desc: "City name"
#
#     def call(city:)
#       "The weather in #{city} is sunny"
#     end
#   end
#
# @example Use a tool
#   tool = WeatherTool.new
#   result = tool.call(city: "San Francisco")
#   # Or use Ruby-like syntax:
#   result = tool.("San Francisco")
module Agents
  class Tool < RubyLLM::Tool
    class << self
      # Enhanced parameter definition with Ruby type classes
      # @param name [Symbol] The parameter name
      # @param type [Class, String] Ruby class (String, Integer) or JSON type string
      # @param desc [String] Description of the parameter
      # @param required [Boolean] Whether the parameter is required
      # @param default [Object] Default value for the parameter
      def param(name, type = String, desc = nil, required: true, default: nil, **options)
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

        # Handle required parameter logic with defaults
        is_required = required && default.nil?

        # Store default value for later use
        @parameter_defaults ||= {}
        @parameter_defaults[name] = default unless default.nil?

        # Call parent param method
        super(name, type: json_type, desc: desc, required: is_required, **options)
      end

      # Get parameter defaults
      # @return [Hash] Hash of parameter names to default values
      def parameter_defaults
        @parameter_defaults ||= {}
      end
    end

    # Ruby-like callable interface - override RubyLLM's execute
    # @param args [Hash] Keyword arguments for the tool
    # @return [Object] Tool execution result
    def call(**args)
      # Apply defaults for missing parameters
      args_with_defaults = apply_defaults(args)

      # Validate parameters
      validate_params(**args_with_defaults)

      # Call the implementation
      execute(**args_with_defaults)
    end

    # Support for proc-like behavior: tool.("arg1", "arg2")
    # @param args [Array] Positional arguments
    # @return [Object] Tool execution result
    def to_proc
      method(:call).to_proc
    end

    # Support for [] syntax: tool["arg"]
    alias [] call

    # Main execution method - override in subclasses
    # @param args [Hash] Keyword arguments for the tool
    # @return [Object] Tool execution result
    def execute(**args)
      raise NotImplementedError, "Subclasses must implement #execute or #call"
    end

    # Override RubyLLM's call to use our enhanced call method
    # This ensures compatibility with RubyLLM's tool system
    # @param args [Hash] Arguments from RubyLLM
    # @return [Object] Tool execution result
    def call_from_llm(args)
      call(**args.transform_keys(&:to_sym))
    end

    # Alias RubyLLM's original call method
    alias ruby_llm_call call

    # Override call to use our enhanced version
    def call(*args, **kwargs)
      if args.empty?
        # Keyword arguments only - our enhanced call
        super(**kwargs)
      else
        # Mixed or positional args - convert to keyword args if single hash
        unless args.length == 1 && args.first.is_a?(Hash) && kwargs.empty?
          raise ArgumentError, "Use keyword arguments for tool calls"
        end

        ruby_llm_call(args.first)

      end
    end

    private

    # Apply default values to arguments
    # @param args [Hash] Input arguments
    # @return [Hash] Arguments with defaults applied
    def apply_defaults(args)
      defaults = self.class.parameter_defaults
      defaults.merge(args)
    end

    # Validate parameters against the defined schema
    # @param args [Hash] Arguments to validate
    # @return [Boolean] True if valid
    # @raise [ArgumentError] If validation fails
    def validate_params(**args)
      parameters.each do |name, param|
        # Check required parameters
        raise ArgumentError, "Missing required parameter: #{name}" if param.required && !args.key?(name)

        # Type validation would go here if needed
        # For now, we rely on JSON schema validation in RubyLLM
      end

      true
    end
  end
end
