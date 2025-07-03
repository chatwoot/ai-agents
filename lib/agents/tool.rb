# frozen_string_literal: true

# Tool is the base class for all agent tools, providing a thread-safe interface for
# agents to interact with external systems and perform actions. Tools extend RubyLLM::Tool
# while adding critical thread-safety guarantees and enhanced error handling.
#
# ## Thread-Safe Design Principles
# Tools extend RubyLLM::Tool but maintain thread safety by:
# 1. **No execution state in instance variables** - Only configuration
# 2. **All state passed through parameters** - ToolContext as first param
# 3. **Immutable tool instances** - Create once, use everywhere
# 4. **Stateless perform methods** - Pure functions with context input
#
# ## Why Thread Safety Matters
# In a multi-agent system, the same tool instance may be used concurrently by different
# agents running in separate threads or fibers. Storing execution state in instance
# variables would cause race conditions and data corruption.
#
# @example Defining a thread-safe tool
#   class WeatherTool < Agents::Tool
#     name "get_weather"
#     description "Get current weather for a location"
#     param :location, type: "string", desc: "City name or coordinates"
#
#     def perform(tool_context, location:)
#       # All state comes from parameters - no instance variables!
#       api_key = tool_context.context[:weather_api_key]
#       cache_duration = tool_context.context[:cache_duration] || 300
#
#       begin
#         # Make API call...
#         "Sunny, 72°F in #{location}"
#       rescue => e
#         "Weather service unavailable: #{e.message}"
#       end
#     end
#   end
#
# @example Using the functional tool definition
#   # Define a calculator tool
#   calculator = Agents::Tool.tool(
#     "calculate",
#     description: "Perform mathematical calculations"
#   ) do |tool_context, expression:|
#     begin
#       result = eval(expression)
#       result.to_s
#     rescue => e
#       "Calculation error: #{e.message}"
#     end
#   end
#
#   # Use the tool in an agent
#   agent = Agents::Agent.new(
#     name: "Math Assistant",
#     instructions: "You are a helpful math assistant",
#     tools: [calculator]
#   )
#
#   # During execution, the runner would call it like this:
#   run_context = Agents::RunContext.new({ user_id: 123 })
#   tool_context = Agents::ToolContext.new(run_context: run_context)
#
#   result = calculator.execute(tool_context, expression: "2 + 2 * 3")
#   # => "8"
module Agents
  class Tool < RubyLLM::Tool
    class << self
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

    # Execute the tool with context injection.
    # This method is called by the runner and handles the thread-safe
    # execution pattern by passing all state through parameters.
    #
    # @param tool_context [Agents::ToolContext] The execution context containing shared state and usage tracking
    # @param params [Hash] Tool-specific parameters as defined by the tool's param declarations
    # @return [String] The tool's result
    def execute(tool_context, **params)
      perform(tool_context, **params)
    end

    # RubyLLM compatibility method - handles both positional and keyword arguments
    # This method provides backward compatibility and flexibility for different calling patterns.
    #
    # @param args [Array] Positional arguments (typically empty, but handled for compatibility)
    # @param params [Hash] Keyword arguments passed to the tool
    # @return [String] The tool's result
    def call(*args, **params)
      # Combine positional args (if they're hashes) with keyword params
      combined_params = if args.any? && args.all? { |arg| arg.is_a?(Hash) }
                          args.inject({}) { |acc, arg| acc.merge(arg) }.merge(params)
                        else
                          params
                        end

      # If we don't have a context (direct RubyLLM call), create a minimal one
      # This should not normally happen in our system, but provides a fallback
      if Thread.current[:tool_context]
        tool_context = Thread.current[:tool_context]
      else
        # Fallback context for direct calls - this is not ideal but prevents crashes
        run_context = Agents::RunContext.new({})
        tool_context = Agents::ToolContext.new(run_context: run_context)
      end

      perform(tool_context, **combined_params)
    end

    # Perform the tool's action. Subclasses must implement this method.
    # This is where the actual tool logic lives. The method receives all
    # execution state through parameters, ensuring thread safety.
    #
    # @param tool_context [Agents::ToolContext] The execution context
    # @param params [Hash] Tool-specific parameters
    # @return [String] The tool's result
    # @raise [NotImplementedError] If not implemented by subclass
    # @example Implementing perform in a subclass
    #   class SearchTool < Agents::Tool
    #     def perform(tool_context, query:, max_results: 10)
    #       api_key = tool_context.context[:search_api_key]
    #       results = SearchAPI.search(query, api_key: api_key, limit: max_results)
    #       results.map(&:title).join("\n")
    #     end
    #   end
    def perform(tool_context, **params)
      raise NotImplementedError, "Tools must implement #perform(tool_context, **params)"
    end

    # Create a tool instance using a functional style definition.
    # This is an alternative to creating a full class for simple tools.
    # The block becomes the tool's perform method.
    #
    # @param name [String] The tool's name (used in function calling)
    # @param description [String] Brief description of what the tool does
    # @yield [tool_context, **params] The block that implements the tool's logic
    # @return [Agents::Tool] A new tool instance
    # @example Creating a simple tool functionally
    #   math_tool = Agents::Tool.tool(
    #     "add_numbers",
    #     description: "Add two numbers together"
    #   ) do |tool_context, a:, b:|
    #     (a + b).to_s
    #   end
    #
    # @example Tool accessing context with error handling
    #   greeting_tool = Agents::Tool.tool("greet", description: "Greet a user") do |tool_context, name:|
    #     language = tool_context.context[:language] || "en"
    #     case language
    #     when "es" then "¡Hola, #{name}!"
    #     when "fr" then "Bonjour, #{name}!"
    #     else "Hello, #{name}!"
    #     end
    #   rescue => e
    #     "Sorry, I couldn't greet you: #{e.message}"
    #   end
    def self.tool(name, description: "", &block)
      # Create anonymous class that extends Tool
      tool_class = Class.new(Tool) do
        define_method :perform, &block
      end

      # Set class-level metadata using define_singleton_method instead of self.name=
      tool_class.define_singleton_method(:name) { name }
      tool_class.define_singleton_method(:description) { description }

      tool_class.new
    end
  end
end
