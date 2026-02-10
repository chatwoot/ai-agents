# frozen_string_literal: true

module Agents
  # Manager for handling and emitting callback events in a thread-safe manner.
  # Provides both generic emit() method and typed convenience methods.
  #
  # @example Using generic emit
  #   manager.emit(:tool_start, tool_name, args)
  #
  # @example Using typed methods
  #   manager.emit_tool_start(tool_name, args)
  #   manager.emit_agent_thinking(agent_name, input)
  class CallbackManager
    # Supported callback event types
    EVENT_TYPES = %i[
      run_start
      run_complete
      agent_complete
      tool_start
      tool_complete
      agent_thinking
      agent_handoff
      llm_call_complete
      chat_created
    ].freeze

    def initialize(callbacks = {})
      @callbacks = callbacks.dup.freeze
    end

    # Generic method to emit any callback event type.
    # Handles arity-aware dispatch: lambdas with strict arity receive only the
    # arguments they expect (extra trailing args are sliced off), while procs
    # and blocks (which have flexible arity) receive all arguments.
    # This ensures backwards compatibility when new arguments (e.g. context_wrapper)
    # are appended to existing callback signatures.
    #
    # @param event_type [Symbol] The type of event to emit
    # @param args [Array] Arguments to pass to callbacks
    def emit(event_type, *args)
      callback_list = @callbacks[event_type] || []

      callback_list.each do |callback|
        safe_args = arity_safe_args(callback, args)
        callback.call(*safe_args)
      rescue StandardError => e
        # Log callback errors but don't let them crash execution
        warn "Callback error for #{event_type}: #{e.message}"
      end
    end

    # Metaprogramming: Create typed emit methods for each event type
    #
    # This generates methods like:
    #   emit_tool_start(tool_name, args)
    #   emit_tool_complete(tool_name, result)
    #   emit_agent_thinking(agent_name, input)
    #   emit_agent_handoff(from_agent, to_agent, reason)
    EVENT_TYPES.each do |event_type|
      define_method("emit_#{event_type}") do |*args|
        emit(event_type, *args)
      end
    end

    private

    # Returns args sliced to fit the callback's accepted parameter count.
    #
    # Non-lambda procs/blocks silently ignore extra args, so they always get all args.
    # Lambdas enforce strict argument counts and will raise ArgumentError on extras —
    # even lambdas with optional params (e.g. ->(a, b, c = nil) {}) have a max.
    # We inspect #parameters to compute the max and slice accordingly.
    # Lambdas with a *rest parameter accept unlimited args, so we pass everything.
    def arity_safe_args(callback, args)
      return args unless callback.lambda?
      return args if callback.parameters.any? { |type, _| type == :rest }

      max = callback.parameters.count { |type, _| %i[req opt].include?(type) }
      args.first(max)
    end
  end
end
