# frozen_string_literal: true

module Agents
  # A thread-safe wrapper that bridges RubyLLM's tool execution with our context injection pattern.
  # This wrapper solves a critical problem: RubyLLM calls tools with just the LLM-provided
  # parameters, but our tools need access to the execution context for shared state.
  #
  # ## The Thread Safety Problem
  # Without this wrapper, we'd need to store context in tool instance variables, which would
  # cause race conditions when the same tool is used by multiple concurrent requests:
  #
  #   # UNSAFE - Don't do this!
  #   class BadTool < Agents::Tool
  #     def set_context(ctx)
  #       @context = ctx  # Race condition!
  #     end
  #   end
  #
  # ## The Solution
  # Each Runner creates new wrapper instances for each execution, capturing the context
  # in the wrapper's closure. When RubyLLM calls execute(), the wrapper injects the
  # context before calling the actual tool:
  #
  #   # Runner creates wrapper
  #   wrapped = ToolWrapper.new(my_tool, context_wrapper)
  #
  #   # RubyLLM calls wrapper
  #   wrapped.execute(city: "NYC")  # No context parameter
  #
  #   # Wrapper injects context
  #   tool_context = ToolContext.new(run_context: context_wrapper)
  #   my_tool.execute(tool_context, city: "NYC")  # Context injected!
  #
  # This ensures each execution has its own context without any shared mutable state.
  class ToolWrapper
    def initialize(tool, context_wrapper)
      @tool = tool
      @context_wrapper = context_wrapper

      # Copy tool metadata for RubyLLM
      @name = tool.name
      @description = tool.description
      @params = tool.class.params if tool.class.respond_to?(:params)
    end

    # RubyLLM calls this method (follows RubyLLM::Tool pattern)
    def call(args)
      tool_context = ToolContext.new(run_context: @context_wrapper)

      # Emit tool start event
      emit_event(:tool_start, @tool.name, args)

      begin
        result = @tool.execute(tool_context, **args.transform_keys(&:to_sym))

        # Emit tool complete event
        emit_event(:tool_complete, @tool.name, result)

        result
      rescue StandardError => e
        # Emit tool complete event even on error, but with error result
        emit_event(:tool_complete, @tool.name, "ERROR: #{e.message}")
        raise
      end
    end

    # Delegate metadata methods to the tool
    def name
      @name || @tool.name
    end

    def description
      @description || @tool.description
    end

    # RubyLLM calls this to get parameter definitions
    def parameters
      @tool.parameters
    end

    # Make this work with RubyLLM's tool calling
    def to_s
      name
    end

    private

    # Emit callback events safely without disrupting tool execution
    def emit_event(event_type, *args)
      callbacks = @context_wrapper.callbacks || {}
      callback_list = callbacks[event_type] || []

      callback_list.each do |callback|
        callback.call(*args)
      rescue StandardError => e
        # Log callback errors but don't let them crash tool execution
        # In a real implementation, you might want to use a proper logger
        warn "Callback error for #{event_type}: #{e.message}"
      end
    end
  end
end
