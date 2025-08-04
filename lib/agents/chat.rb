# frozen_string_literal: true

require_relative "tool_context"

module Agents
  # Extended chat class that inherits from RubyLLM::Chat but adds proper handoff handling.
  # This solves the infinite handoff loop problem by treating handoffs as turn-ending
  # operations rather than allowing auto-continuation.
  class Chat < RubyLLM::Chat
    # Response object that indicates a handoff occurred
    class HandoffResponse
      attr_reader :target_agent, :response, :handoff_message

      def initialize(target_agent:, response:, handoff_message:)
        @target_agent = target_agent
        @response = response
        @handoff_message = handoff_message
      end

      def tool_call?
        true
      end

      def content
        @handoff_message
      end
    end

    def initialize(model: nil, handoff_tools: [], context_wrapper: nil, temperature: nil, response_schema: nil,
                   **options)
      super(model: model, **options)
      @handoff_tools = handoff_tools
      @context_wrapper = context_wrapper

      # Set temperature if provided (RubyLLM::Chat sets this via accessor)
      @temperature = temperature if temperature

      # Set response schema if provided
      with_schema(response_schema) if response_schema

      # Register handoff tools with RubyLLM for schema generation
      @handoff_tools.each { |tool| with_tool(tool) }
    end

    # Override the problematic auto-execution method from RubyLLM::Chat
    def complete(&block)
      @on[:new_message]&.call
      response = @provider.complete(
        messages,
        tools: @tools,
        temperature: @temperature,
        model: @model.id,
        connection: @connection,
        params: @params,
        schema: @schema,
        &block
      )
      @on[:end_message]&.call(response)

      # Handle JSON parsing for structured output (like RubyLLM::Chat)
      if @schema && response.content.is_a?(String)
        begin
          response.content = JSON.parse(response.content)
        rescue JSON::ParserError
          # If parsing fails, keep content as string
        end
      end

      add_message(response)

      if response.tool_call?
        handle_tools_with_handoff_detection(response, &block)
      else
        response
      end
    end

    private

    def handle_tools_with_handoff_detection(response, &block)
      handoff_calls, regular_calls = classify_tool_calls(response.tool_calls)

      if handoff_calls.any?
        # Execute first handoff only
        handoff_result = execute_handoff_tool(handoff_calls.first)

        # Add tool result to conversation
        add_tool_result(handoff_calls.first.id, handoff_result[:message])

        # Return handoff response to signal agent switch (ends turn)
        HandoffResponse.new(
          target_agent: handoff_result[:target_agent],
          response: response,
          handoff_message: handoff_result[:message]
        )
      else
        # Use RubyLLM's original tool execution for regular tools
        execute_regular_tools_and_continue(regular_calls, &block)
      end
    end

    def classify_tool_calls(tool_calls)
      handoff_tool_names = @handoff_tools.map(&:name).map(&:to_s)

      handoff_calls = []
      regular_calls = []

      tool_calls.each_value do |tool_call|
        if handoff_tool_names.include?(tool_call.name)
          handoff_calls << tool_call
        else
          regular_calls << tool_call
        end
      end

      [handoff_calls, regular_calls]
    end

    def execute_handoff_tool(tool_call)
      tool = @handoff_tools.find { |t| t.name.to_s == tool_call.name }
      raise "Handoff tool not found: #{tool_call.name}" unless tool

      # Execute the handoff tool directly with context
      tool_context = ToolContext.new(run_context: @context_wrapper)
      result = tool.execute(tool_context, **{}) # Handoff tools take no additional params

      {
        target_agent: tool.target_agent,
        message: result.to_s
      }
    end

    def execute_regular_tools_and_continue(tool_calls, &block)
      # Execute each regular tool call
      tool_calls.each do |tool_call|
        @on[:new_message]&.call
        result = execute_tool(tool_call)
        message = add_tool_result(tool_call.id, result)
        @on[:end_message]&.call(message)
      end

      # Continue conversation after tool execution
      complete(&block)
    end

    # Reuse RubyLLM's existing tool execution logic
    def execute_tool(tool_call)
      tool = tools[tool_call.name.to_sym]
      args = tool_call.arguments
      tool.call(args)
    end

    def add_tool_result(tool_use_id, result)
      add_message(
        role: :tool,
        content: result.is_a?(Hash) && result[:error] ? result[:error] : result.to_s,
        tool_call_id: tool_use_id
      )
    end
  end
end
