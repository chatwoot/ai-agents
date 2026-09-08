# frozen_string_literal: true

require "forwardable"

module Agents
  # Binds application state to a tool for one run, without mutating the shared tool.
  class ToolWrapper
    extend Forwardable

    def_delegators :@tool, :name, :description, :parameters_schema, :provider_options,
                   :requires_approval?, :approval_resolver

    def initialize(tool, context_wrapper)
      @tool = tool
      @context_wrapper = context_wrapper
    end

    # RubyLLM reserves tool_call: for invocation metadata, not model arguments.
    # https://rubyllm.com/next/upgrading/#api-changes
    def call(tool_call: nil, **args)
      tool_context = ToolContext.new(run_context: @context_wrapper, tool_call: tool_call)
      @tool.execute(tool_context, **args.transform_keys(&:to_sym))
    end
  end
end
