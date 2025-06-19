# frozen_string_literal: true

# Slim wrapper around RubyLLM::Tool with Ruby-like parameter syntax.
#
# @example Define a simple tool
#   class WeatherTool < Agents::Tool
#     description "Get current weather for a city"
#     param :city, String, "City name"
#
#     def execute(city:)
#       "The weather in #{city} is sunny"
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

    # Support for proc-like behavior and [] syntax
    def to_proc
      method(:execute).to_proc
    end

    alias [] execute
  end
end
