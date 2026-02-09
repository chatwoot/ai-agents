# frozen_string_literal: true

require_relative "instrumentation/constants"
require_relative "instrumentation/tracing_callbacks"

module Agents
  # Optional OpenTelemetry instrumentation for the ai-agents gem.
  # Emits OTel spans for LLM calls, tool executions, and agent handoffs
  # that render correctly in Langfuse and other OTel-compatible backends.
  #
  # The gem only emits spans — the consumer configures the OTel exporter
  # and provides a tracer. The opentelemetry-api gem is NOT declared as a
  # dependency; consumers must include it in their own bundle.
  #
  # @example Basic usage
  #   require 'agents/instrumentation'
  #
  #   tracer = OpenTelemetry.tracer_provider.tracer('my_app')
  #   runner = Agents::Runner.with_agents(triage, billing, support)
  #
  #   Agents::Instrumentation.install(runner, tracer: tracer)
  #
  # @example With custom trace name
  #   Agents::Instrumentation.install(runner,
  #     tracer: tracer,
  #     trace_name: 'customer_support.run'
  #   )
  #
  # @example With Langfuse attributes
  #   Agents::Instrumentation.install(runner,
  #     tracer: tracer,
  #     span_attributes: { 'langfuse.trace.tags' => ['v2'].to_json },
  #     attribute_provider: ->(ctx) {
  #       { 'langfuse.user.id' => ctx.context[:account_id].to_s }
  #     }
  #   )
  module Instrumentation
    INSTALL_MUTEX = Mutex.new
    private_constant :INSTALL_MUTEX

    INSTRUMENTATION_FLAG_IVAR = :@__agents_otel_instrumentation_installed
    private_constant :INSTRUMENTATION_FLAG_IVAR

    # Install OTel tracing on a runner via callbacks.
    # No-op if opentelemetry-api is not available.
    # Idempotent per runner instance: first install wins.
    #
    # Session grouping: set `context[:session_id]` when calling `runner.run()`.
    # TracingCallbacks automatically reads it per-request and sets `langfuse.session.id`.
    #
    # @param runner [Agents::AgentRunner] The runner to instrument
    # @param tracer [OpenTelemetry::Trace::Tracer] OTel tracer instance
    # @param trace_name [String] Name for the root span (default: "agents.run")
    # @param span_attributes [Hash] Static attributes applied to the root span
    # @param attribute_provider [Proc, nil] Lambda receiving context_wrapper, returning dynamic attributes
    # @return [Agents::AgentRunner, nil] The runner (for chaining), or nil if OTel is unavailable
    def self.install(runner, tracer:, trace_name: Constants::SPAN_RUN, span_attributes: {},
                     attribute_provider: nil)
      return unless otel_available?

      INSTALL_MUTEX.synchronize do
        return runner if instrumentation_installed?(runner)

        callbacks = TracingCallbacks.new(
          tracer: tracer,
          trace_name: trace_name,
          span_attributes: span_attributes,
          attribute_provider: attribute_provider
        )

        register_callbacks(runner, callbacks)
        mark_instrumentation_installed(runner)
      end
      runner
    end

    # Callback event types that are forwarded from the runner to TracingCallbacks.
    TRACED_EVENTS = CallbackManager::EVENT_TYPES
    private_constant :TRACED_EVENTS

    # Register all tracing callback handlers on the runner.
    def self.register_callbacks(runner, callbacks)
      TRACED_EVENTS.each do |event|
        runner.public_send(:"on_#{event}") { |*args| callbacks.public_send(:"on_#{event}", *args) }
      end
    end
    private_class_method :register_callbacks

    def self.instrumentation_installed?(runner)
      runner.instance_variable_get(INSTRUMENTATION_FLAG_IVAR)
    end
    private_class_method :instrumentation_installed?

    def self.mark_instrumentation_installed(runner)
      runner.instance_variable_set(INSTRUMENTATION_FLAG_IVAR, true)
    end
    private_class_method :mark_instrumentation_installed

    # Check if the opentelemetry-api gem is available.
    #
    # @return [Boolean] true if opentelemetry-api can be loaded
    def self.otel_available?
      require "opentelemetry-api"
      true
    rescue LoadError
      false
    end
  end
end
