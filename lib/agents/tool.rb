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
      Tracing.in_span("tool.#{name}", kind: :internal,
                      "tool.name" => name,
                      "tool.class" => self.class.name,
                      "tool.description" => description || "no description",
                      "tool.param_count" => params.keys.length,
                      "tool.param_names" => params.keys.join(","),
                      "tool.context_available" => !tool_context.nil?,
                      "tool.run_context_keys" => tool_context&.context&.keys&.join(",") || "none") do |span|
        
        # Add parameter details if sensitive data is allowed
        if Agents.configuration.tracing.include_sensitive_data
          params.each do |key, value|
            span.set_attribute("tool.param.#{key}", value.to_s) if value.to_s.length < 200
          end
        end
        
        span.add_event("tool.execution_started", attributes: {
          "execution.context_size" => tool_context&.context&.keys&.length || 0,
          "execution.params_provided" => params.keys.length
        })
        
        start_time = Time.now
        begin
          result = perform(tool_context, **params)
          duration = Time.now - start_time
          
          # Add comprehensive execution metadata
          span.set_attribute("tool.execution_time_ms", (duration * 1000).round(2))
          span.set_attribute("tool.execution_success", true)
          span.set_attribute("tool.result_type", result.class.name)
          span.set_attribute("tool.result_length", result.to_s.length)
          
          # Add result to span if not sensitive and reasonable size
          if Agents.configuration.tracing.include_sensitive_data && result.is_a?(String) && result.length < 1000
            span.set_attribute("tool.result", result)
          end
          
          span.add_event("tool.execution_completed", attributes: {
            "execution.duration_ms" => (duration * 1000).round(2),
            "execution.result_size" => result.to_s.length,
            "execution.success" => true
          })
          
          result
        rescue => e
          duration = Time.now - start_time
          span.set_attribute("tool.execution_time_ms", (duration * 1000).round(2))
          span.set_attribute("tool.execution_success", false)
          span.set_attribute("tool.error_type", e.class.name)
          span.set_attribute("tool.error_message", e.message)
          
          span.add_event("tool.execution_failed", attributes: {
            "execution.duration_ms" => (duration * 1000).round(2),
            "execution.error" => e.class.name,
            "execution.error_message" => e.message,
            "execution.stacktrace" => e.backtrace&.first(3)&.join("\n") || "unknown"
          })
          
          raise
        end
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
      Class.new(Tool) do
        self.name = name
        self.description = description

        define_method :perform, &block
      end.new
    end
  end
end
