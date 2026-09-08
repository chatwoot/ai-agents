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
      @run_context.callback_manager.emit_native_event(phase, name, payload, @run_context)
    end
  end
end
