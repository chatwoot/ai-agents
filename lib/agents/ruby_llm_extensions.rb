# frozen_string_literal: true

require "ruby_llm"

module Agents
  # This module enhances RubyLLM's tool execution to support:
  # 1. Parallel tool execution (performance optimization)
  # 2. Proper error handling with our failure_error_function
  # 3. Better visibility into tool execution for debugging
  #
  # ## Why We Monkey Patch
  #
  # RubyLLM's default behavior executes tools sequentially and synchronously.
  # While this works, it has limitations:
  # - Tools execute one at a time (slow for multiple tools)
  # - No support for custom error handling
  # - Limited visibility into execution
  #
  # ## How We Enhance It
  #
  # We use Ruby's `prepend` to override the `handle_tool_calls` method while
  # preserving the ability to call the original implementation with `super`.
  # This is the safest form of monkey patching because:
  # - We can fall back to original behavior if needed
  # - Method resolution order is clear and predictable
  # - Easy to disable by not loading this file
  #
  # ## Implementation Details
  #
  # RubyLLM's original flow:
  #   1. handle_tool_calls iterates through tool_calls
  #   2. For each tool call:
  #      - execute_tool is called
  #      - Result is added with add_tool_result
  #      - Callbacks are triggered
  #   3. complete() is called recursively
  #
  # Our enhancement:
  #   1. Check if we have multiple tools and Async is available
  #   2. If yes, execute tools in parallel using Async tasks
  #   3. Maintain all the same callbacks and message handling
  #   4. Fall back to sequential execution for single tools
  #
  # ## Maintenance Considerations
  #
  # This patch is tied to RubyLLM's internal implementation. When upgrading
  # RubyLLM, check if:
  # 1. The handle_tool_calls method signature has changed
  # 2. The tool execution flow has been modified
  # 3. New callbacks or events have been added
  #
  # If RubyLLM's implementation changes significantly, we may need to update
  # this patch or find alternative integration points.
  #
  # ## Testing the Monkey Patch
  #
  # To verify the patch is working:
  #   1. Create an agent with multiple tools
  #   2. Trigger a response that calls multiple tools
  #   3. Check logs for "[Agents] Executing N tools in parallel"
  #   4. Verify tools execute faster than sequential
  #
  module AsyncToolExecution
    # Override handle_tool_calls to add parallel execution
    # This method is called by RubyLLM when the LLM response includes tool calls
    def handle_tool_calls(response, &block)
      tool_count = response.tool_calls&.size || 0

      # Only use async if we have multiple tools and Async is available
      if defined?(Async) && tool_count > 1
        Agents.logger&.debug "[Agents] Executing #{tool_count} tools in parallel"
        handle_tool_calls_async(response, &block)
      else
        # Fall back to original sequential execution
        # This ensures compatibility and safety
        super
      end
    end

    private

    # Execute multiple tool calls in parallel using the Async gem
    # This can significantly improve performance when multiple tools are called
    def handle_tool_calls_async(response, &block)
      # Execute all tool calls in parallel using Async
      Async do |task|
        tool_results = response.tool_calls.map do |id, tool_call|
          # Create an async task for each tool call
          task.async do
            execute_single_tool(tool_call, id)
          end
        end.map(&:wait).to_h

        # Check if any tools failed and log for monitoring
        failed_count = tool_results.values.count { |r| !r[:success] }
        if failed_count.positive?
          Agents.logger&.warn "[Agents] #{failed_count} tool(s) failed during parallel execution"
        end
      end

      # Continue the conversation with tool results added
      # This maintains RubyLLM's expected flow
      complete(&block)
    end

    # Execute a single tool and handle errors gracefully
    # Returns a hash with execution status and result
    def execute_single_tool(tool_call, id)
      # Notify callback about new message (maintain RubyLLM compatibility)
      @on[:new_message]&.call

      begin
        # Execute the tool (our wrapper handles context injection)
        result = execute_tool(tool_call)

        # Add the result as a tool message
        message = add_tool_result(tool_call.id, result)

        # Notify callback about completed message
        @on[:end_message]&.call(message)

        [id, { success: true, message: message }]
      rescue StandardError => e
        # Enhanced error handling
        Agents.logger&.error "[Agents] Tool execution failed: #{tool_call.name}", error: e

        # Try to get a better error message if the tool has a failure handler
        error_result = if tool_responds_to_failure_handler?(tool_call)
                         handle_tool_failure(tool_call, e)
                       else
                         "Tool execution failed: #{e.message}"
                       end

        # Add error as tool result so LLM knows what happened
        message = add_tool_result(tool_call.id, error_result)
        @on[:end_message]&.call(message)

        [id, { success: false, message: message, error: e }]
      end
    end

    # Check if the tool might have a failure handler
    # This is a heuristic since we can't always access the tool instance directly
    def tool_responds_to_failure_handler?(tool_call)
      tool = tools[tool_call.name.to_sym]
      return false unless tool

      # Check if it's wrapped
      if tool.respond_to?(:execute)
        # Try to check the underlying tool
        tool.instance_variable_defined?(:@tool) &&
          tool.instance_variable_get(:@tool).respond_to?(:failure_error_function)
      else
        false
      end
    end

    # Attempt to use the tool's failure handler if available
    def handle_tool_failure(tool_call, error)
      tool = tools[tool_call.name.to_sym]
      return "Tool execution failed: #{error.message}" unless tool

      # This is a best effort - we may not have access to the context
      # but at least we can provide a better error message
      if tool.instance_variable_defined?(:@tool)
        actual_tool = tool.instance_variable_get(:@tool)
        if actual_tool.respond_to?(:failure_error_function) && actual_tool.failure_error_function
          # We don't have the tool context here, so pass nil
          # Tools should handle nil context gracefully in error handlers
          actual_tool.failure_error_function.call(error, nil)
        else
          "Tool execution failed: #{error.message}"
        end
      else
        "Tool execution failed: #{error.message}"
      end
    rescue StandardError => e
      # If the error handler itself fails, return original error
      Agents.logger&.error "[Agents] Failure handler error", error: e
      "Tool execution failed: #{error.message}"
    end
  end

  # Logger accessor for the Agents module
  # Can be configured by users of the gem
  class << self
    attr_accessor :logger
  end
end

# Apply the monkey patch to RubyLLM::Chat
# This must be done after RubyLLM is loaded
# The prepend ensures our methods take precedence while allowing super calls
RubyLLM::Chat.prepend(Agents::AsyncToolExecution)
