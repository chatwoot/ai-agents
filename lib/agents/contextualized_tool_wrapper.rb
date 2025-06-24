# frozen_string_literal: true

module Agents
  # ContextualizedToolWrapper wraps our Agents::Tool instances to provide proper
  # context injection when RubyLLM executes them. This is a critical component
  # for thread safety and proper context management.
  #
  # ## Why We Need This Wrapper
  #
  # RubyLLM's tool execution flow works like this:
  # 1. LLM returns tool calls in its response
  # 2. RubyLLM's handle_tool_calls method executes each tool
  # 3. Tools are called with just the arguments from the LLM
  #
  # The problem: Our tools need a ToolContext object as the first parameter
  # for thread-safe execution, but RubyLLM doesn't know about this requirement.
  #
  # ## How This Wrapper Solves It
  #
  # We wrap each tool before passing it to RubyLLM. When RubyLLM calls the
  # wrapper's execute method, we:
  # 1. Create a ToolContext from the captured context_wrapper
  # 2. Call our tool's execute method with proper context injection
  # 3. Return the result to RubyLLM
  #
  # This ensures every tool execution has its own isolated context, preventing
  # race conditions in concurrent environments.
  #
  # ## Thread Safety Guarantees
  #
  # Each tool execution gets a fresh ToolContext, ensuring:
  # - No shared mutable state between executions
  # - Context isolation between concurrent tool calls
  # - Safe execution even when the same tool is called multiple times
  #
  # ## Example Flow
  #
  #   # In Runner#call_llm
  #   wrapped_tool = ContextualizedToolWrapper.new(calculator_tool, context_wrapper)
  #
  #   # RubyLLM calls our wrapper
  #   result = wrapped_tool.execute({ expression: "2 + 2" })
  #
  #   # Inside execute, we create ToolContext and call the real tool
  #   tool_context = ToolContext.new(run_context: context_wrapper)
  #   calculator_tool.execute(tool_context, expression: "2 + 2")
  #
  class ContextualizedToolWrapper
    def initialize(tool, context_wrapper)
      @tool = tool
      @context_wrapper = context_wrapper

      # Freeze to prevent accidental modification
      freeze
    end

    # RubyLLM calls this method when executing tools.
    # We intercept this call to inject our ToolContext before forwarding
    # to the actual tool implementation.
    #
    # @param args [Hash] Arguments from the LLM's tool call
    # @return [String] Tool execution result
    # @example RubyLLM executing a wrapped tool
    #   # RubyLLM's execute_tool method calls:
    #   tool.execute({ city: "San Francisco" })
    #
    #   # We intercept and transform to:
    #   tool.execute(tool_context, city: "San Francisco")
    def execute(args)
      # Create a fresh ToolContext for this execution
      # This ensures thread safety - each execution gets its own context
      tool_context = ToolContext.new(run_context: @context_wrapper)

      # Call our tool's execute method with proper context injection
      # The tool expects (tool_context, **params) but RubyLLM only passes params
      @tool.execute(tool_context, **args)
    end

    # RubyLLM also calls this method (alias for execute)
    # Some versions use `call` instead of `execute`
    def call(args)
      execute(args)
    end

    # Delegate all other methods to the wrapped tool
    # This ensures RubyLLM can access name, description, params, etc.
    # Without this, RubyLLM wouldn't be able to generate proper schemas.
    def method_missing(method, *args, &block)
      @tool.send(method, *args, &block)
    end

    def respond_to_missing?(method, include_private = false)
      @tool.respond_to?(method, include_private)
    end

    # Debugging helper - useful for understanding what's being called
    def inspect
      "#<ContextualizedToolWrapper tool=#{@tool.class.name} context=present>"
    end
  end
end
