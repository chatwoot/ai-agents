# frozen_string_literal: true

module Agents
  # Base class for all tools
  #
  # @example Define a simple tool
  #   class WeatherTool < Agents::ToolBase
  #     name "get_weather"
  #     description "Get current weather for a city"
  #     param :city, "string", "City name", required: true
  #
  #     def perform(city:, context: nil)
  #       "The weather in #{city} is sunny"
  #     end
  #   end
  class ToolBase
    class << self
      attr_reader :tool_name, :tool_description, :tool_parameters

      # Set or get the tool name
      def name(value = nil)
        @tool_name = value if value
        @tool_name || to_s.split("::").last.gsub(/Tool$/, "").downcase
      end

      # Set or get the tool description
      def description(value = nil)
        @tool_description = value if value
        @tool_description || "Tool: #{name}"
      end

      # Define a parameter for this tool
      def param(name, type = "string", description = nil, required: true, **options)
        @tool_parameters ||= {}
        @tool_parameters[name.to_sym] = {
          type: normalize_type(type),
          description: description || name.to_s.tr("_", " ").capitalize,
          required: required,
          **options
        }
      end

      # Get all parameters
      def parameters
        @tool_parameters || {}
      end

      # Generate function schema for LLM function calling
      def to_function_schema
        properties = {}
        required = []

        parameters.each do |param_name, param_config|
          properties[param_name] = {
            type: param_config[:type],
            description: param_config[:description]
          }
          required << param_name if param_config[:required]
        end

        {
          type: "function",
          function: {
            name: name,
            description: description,
            parameters: {
              type: "object",
              properties: properties,
              required: required
            }
          }
        }
      end

      # Create and call tool in one step
      def call(**args)
        new.call(**args)
      end

      private

      def normalize_type(type)
        case type
        when String, :string, "string" then "string"
        when Integer, :integer, "integer" then "integer"
        when Float, :number, "number" then "number"
        when TrueClass, FalseClass, :boolean, "boolean" then "boolean"
        when Array, :array, "array" then "array"
        when Hash, :object, "object" then "object"
        else "string"
        end
      end
    end

    # Set the execution context for this tool instance
    def set_context(context)
      @execution_context = context
    end

    # Call the tool with arguments
    def call(**args)
      # Always pass context to perform method
      perform(context: @execution_context, **args)
    end

    # Generate function schema for this instance
    def to_function_schema
      self.class.to_function_schema
    end

    # Default implementation - subclasses should override this
    def perform(**args)
      raise NotImplementedError, "Tools must implement #perform method"
    end
  end
end
