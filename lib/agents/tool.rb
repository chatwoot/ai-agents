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
#     failure_error_function do |error, tool_context|
#       "Weather service unavailable: #{error.message}"
#     end
#
#     def perform(tool_context, location:)
#       # All state comes from parameters - no instance variables!
#       api_key = tool_context.context[:weather_api_key]
#       cache_duration = tool_context.context[:cache_duration] || 300
#
#       # Make API call...
#       "Sunny, 72°F in #{location}"
#     end
#   end
#
# @example Using the functional tool definition
#   # Define a calculator tool
#   calculator = Agents::Tool.tool(
#     "calculate",
#     description: "Perform mathematical calculations",
#     failure_error_function: ->(e, ctx) { "Calculation error: #{e.message}" }
#   ) do |tool_context, expression:|
#     result = eval(expression)
#     result.to_s
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
    attr_reader :failure_error_function

    class << self
      # Define a custom error handler for this tool class.
      # The error handler receives the exception and tool context,
      # allowing for context-aware error messages.
      #
      # @param func [Proc, nil] A callable that takes (error, tool_context) parameters
      # @yield [error, tool_context] Block form alternative to passing a proc
      # @example Setting an error handler
      #   class DatabaseTool < Agents::Tool
      #     failure_error_function do |error, tool_context|
      #       user = tool_context.context[:user]
      #       "Database error for user #{user}: #{error.message}"
      #     end
      #   end
      def failure_error_function(func = nil, &block)
        @failure_error_function = func || block
      end

      # Internal method to retrieve the failure error function
      # @api private
      def get_failure_error_function
        @failure_error_function
      end
    end

    # Initialize a new tool instance, capturing any class-level error handler
    def initialize
      super
      @failure_error_function = self.class.get_failure_error_function
    end

    # Execute the tool with proper error handling and context injection.
    # This method is called by the agent runner and handles the thread-safe
    # execution pattern by passing all state through parameters.
    #
    # Thread-safe execution - no instance variables for execution state!
    # Override RubyLLM's execute to inject ToolContext.
    #
    # @param tool_context [Agents::ToolContext] The execution context containing shared state and usage tracking
    # @param params [Hash] Tool-specific parameters as defined by the tool's param declarations
    # @return [String] The tool's result or error message
    # @example Runner executing a tool
    #   tool_context = Agents::ToolContext.new(run_context: run_context)
    #   result = weather_tool.execute(tool_context, location: "San Francisco")
    def execute(tool_context, **params)
      # Call perform with tool_context as first parameter
      perform(tool_context, **params)
    rescue StandardError => e
      # Use failure_error_function if provided, like OpenAI
      if @failure_error_function
        @failure_error_function.call(e, tool_context)
      else
        # Default error format
        "Error executing #{self.class.name}: #{e.message}"
      end
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

    # Generate JSON schema for LLM function calling
    # TODO: Implement this method to generate OpenAI-compatible function schemas
    # This method should return a hash that describes the tool in OpenAI's function calling format
    #
    # Expected return format:
    # {
    #   "type": "function",
    #   "function": {
    #     "name": "tool_name",
    #     "description": "Tool description",
    #     "parameters": {
    #       "type": "object",
    #       "properties": {
    #         "param1": {
    #           "type": "string",
    #           "description": "Description of param1"
    #         },
    #         "param2": {
    #           "type": "integer",
    #           "description": "Description of param2"
    #         }
    #       },
    #       "required": ["param1"]
    #     }
    #   }
    # }
    #
    # Implementation steps:
    # 1. Get tool name from self.class.name
    # 2. Get tool description from self.class.description
    # 3. Iterate through self.class.params to build properties (skip :tool_context)
    # 4. Determine required params (those without required: false)
    # 5. Return the properly formatted hash
    def to_json_schema
      # Dummy implementation - replace with actual schema generation
      {
        type: "function",
        function: {
          name: self.class.name || "unnamed_tool",
          description: self.class.description || "No description provided",
          parameters: {
            type: "object",
            properties: {},
            required: []
          }
        }
      }
    end

    # Create a tool instance using a functional style definition.
    # This is an alternative to creating a full class for simple tools.
    # The block becomes the tool's perform method.
    #
    # @param name [String] The tool's name (used in function calling)
    # @param description [String] Brief description of what the tool does
    # @param failure_error_function [Proc, nil] Optional error handler
    # @yield [tool_context, **params] The block that implements the tool's logic
    # @return [Agents::Tool] A new tool instance
    # @example Creating a simple tool functionally
    #   math_tool = Agents::Tool.tool(
    #     "add_numbers",
    #     description: "Add two numbers together",
    #     failure_error_function: ->(e, ctx) { "Math error: #{e.message}" }
    #   ) do |tool_context, a:, b:|
    #     (a + b).to_s
    #   end
    #
    # @example Tool accessing context
    #   greeting_tool = Agents::Tool.tool("greet", description: "Greet a user") do |tool_context, name:|
    #     language = tool_context.context[:language] || "en"
    #     case language
    #     when "es" then "¡Hola, #{name}!"
    #     when "fr" then "Bonjour, #{name}!"
    #     else "Hello, #{name}!"
    #     end
    #   end
    def self.tool(name, description: "", failure_error_function: nil, &block)
      # Create anonymous class that extends Tool
      Class.new(Tool) do
        self.name = name
        self.description = description

        define_method :perform, &block

        # Set failure function if provided
        failure_error_function(failure_error_function) if failure_error_function
      end.new
    end
  end
end
