# frozen_string_literal: true

require_relative "tool_context"
require "securerandom"

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

    def initialize(model: nil, handoff_tools: [], context_wrapper: nil, **options)
      super(model: model, **options)
      @handoff_tools = handoff_tools
      @context_wrapper = context_wrapper

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
        &block
      )
      @on[:end_message]&.call(response)

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
        tool_call_id = extract_tool_call_id(handoff_calls.first)
        add_tool_result(tool_call_id, handoff_result[:message])

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

      # Handle both Hash and Array formats for tool_calls
      tool_calls_array = tool_calls.is_a?(Hash) ? tool_calls.values : tool_calls

      tool_calls_array.each do |tool_call|
        # Extract tool name correctly based on tool_call structure
        tool_name = extract_tool_call_name(tool_call)

        if handoff_tool_names.include?(tool_name)
          handoff_calls << tool_call
        else
          regular_calls << tool_call
        end
      end

      [handoff_calls, regular_calls]
    end

    def extract_tool_call_name(tool_call)
      # Handle different tool call formats from various LLM providers
      if tool_call.respond_to?(:name)
        tool_call.name
      elsif tool_call.respond_to?(:function) && tool_call.function
        if tool_call.function.respond_to?(:name)
          tool_call.function.name
        elsif tool_call.function.is_a?(Hash)
          tool_call.function["name"] || tool_call.function[:name]
        end
      elsif tool_call.is_a?(Hash)
        tool_call["name"] || tool_call[:name] ||
          (tool_call["function"] && (tool_call["function"]["name"] || tool_call["function"][:name]))
      else
        tool_call.to_s
      end
    end

    def extract_tool_call_id(tool_call)
      # Handle different tool call ID formats
      if tool_call.respond_to?(:id)
        tool_call.id
      elsif tool_call.is_a?(Hash)
        tool_call["id"] || tool_call[:id]
      else
        SecureRandom.hex(8) # Fallback ID
      end
    end

    def execute_handoff_tool(tool_call)
      tool_name = extract_tool_call_name(tool_call)
      tool = @handoff_tools.find { |t| t.name.to_s == tool_name }
      raise "Handoff tool not found: #{tool_name}" unless tool

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
        tool_call_id = extract_tool_call_id(tool_call)
        message = add_tool_result(tool_call_id, result)
        @on[:end_message]&.call(message)
      end

      # Continue conversation after tool execution
      complete(&block)
    end

    # Reuse RubyLLM's existing tool execution logic
    def execute_tool(tool_call)
      tool_name = extract_tool_call_name(tool_call)
      tool = tools[tool_name.to_sym]

      # Extract arguments correctly
      args = if tool_call.respond_to?(:arguments)
               tool_call.arguments
             elsif tool_call.respond_to?(:function) && tool_call.function.respond_to?(:arguments)
               tool_call.function.arguments
             elsif tool_call.is_a?(Hash) && tool_call["function"]
               tool_call["function"]["arguments"]
             else
               {}
             end

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
