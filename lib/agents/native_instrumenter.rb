# frozen_string_literal: true

module Agents
  # A per-run bridge, leaving the application's RubyLLM instrumenter intact.
  # https://rubyllm.com/next/instrumentation/
  class NativeInstrumenter
    def initialize(run_context, upstream = nil)
      @run_context = run_context
      @upstream = upstream
    end

    def instrument(name, payload)
      @run_context.usage.record(payload) if name == "usage.ruby_llm"
      unless block_given?
        return @upstream.instrument(name, payload) if @upstream.respond_to?(:instrument)

        return
      end

      emit(:start, name, payload)
      if @upstream.respond_to?(:instrument)
        @upstream.instrument(name, payload) { yield }
      else
        yield
      end
    rescue StandardError => e
      payload[:error] = e
      raise
    ensure
      emit(:finish, name, payload) if block_given?
    end

    private

    def emit(phase, name, payload)
      manager = @run_context.callback_manager
      manager.emit_native_event(phase, name, payload, @run_context)
      return unless name == "tool_call.ruby_llm"

      if phase == :start
        manager.emit_tool_start(payload[:tool_name], payload[:tool_arguments], @run_context)
      else
        result = payload[:error] ? "ERROR: #{payload[:error].message}" : payload[:result]
        manager.emit_tool_complete(payload[:tool_name], result, @run_context)
      end
    end
  end
end
