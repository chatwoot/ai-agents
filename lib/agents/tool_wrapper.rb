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
    def execute(**args)
      args = args.transform_keys(&:to_sym)
      Agents.logger.debug "ToolWrapper execute called on #{@tool.class.name} with args: #{args.inspect}"

      # Create tool context with current run context
      tool_context = ToolContext.new(run_context: @context_wrapper)

      Agents.logger.debug "Created tool_context: #{tool_context.class}, calling @tool.perform"

      begin
        # Call the wrapped tool with context and arguments
        result = @tool.perform(tool_context, **args)

        Agents.logger.debug "Tool perform returned: #{result.class} - #{result.to_s[0..50]}..."

        result
      rescue StandardError => e
        error_msg = "Error executing tool #{@tool.class.name}: #{e.message}"
        Agents.logger.error error_msg
        Agents.logger.debug "Backtrace: #{e.backtrace.first(5).join("\n  ")}"
        error_msg
      end
    end

    # Fallback call method for compatibility with tools that expect it
    # This handles cases where MCP tools are accidentally wrapped
    def call(*args, **kwargs)
      # Convert first hash argument to kwargs if needed
      if args.length == 1 && args[0].is_a?(Hash) && kwargs.empty?
        kwargs = args[0].transform_keys(&:to_sym)
        args = []
      end

      # If the wrapped tool has a call method (like MCP tools), use it directly
      if @tool.respond_to?(:call)
        # For Agents::Tool instances, set the context in thread-local variable
        if @tool.is_a?(Agents::Tool)
          tool_context = ToolContext.new(run_context: @context_wrapper)
          Thread.current[:tool_context] = tool_context
          begin
            result = @tool.call(*args, **kwargs)
          ensure
            Thread.current[:tool_context] = nil
          end
          result
        else
          @tool.call(*args, **kwargs)
        end
      else
        # Otherwise, fall back to execute method
        execute(**kwargs)
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

    # Delegate any missing methods to the wrapped tool to ensure compatibility
    def method_missing(method_name, *args, **kwargs, &block)
      if @tool.respond_to?(method_name)
        @tool.send(method_name, *args, **kwargs, &block)
      else
        super
      end
    end

    def respond_to_missing?(method_name, include_private = false)
      @tool.respond_to?(method_name, include_private) || super
    end
  end
end
