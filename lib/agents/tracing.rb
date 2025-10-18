# frozen_string_literal: true

require "json"
require "opentelemetry/sdk"
require "opentelemetry/exporter/otlp"

module Agents
  # OpenTelemetry tracing support for the Agents framework.
  # Provides block-based API for setting trace context and creating custom spans.
  #
  # ## Usage
  #
  #   # Set trace context for a conversation
  #   Agents.with_trace(user_id: "user_123", session_id: "session_abc") do
  #     runner = Agents::Runner.with_agents(agent1, agent2)
  #     result = runner.run("Hello")
  #   end
  #
  #   # Create custom spans
  #   Agents.in_span("custom_operation", type: :task) do |span|
  #     span.set_attribute("custom.attr", "value")
  #     # ... work ...
  #   end
  #
  module Tracing
    class << self
      # Initialize OpenTelemetry SDK with OTLP exporter.
      # Called automatically during Agents.configure if tracing is enabled.
      #
      # @param config [Agents::Configuration] The configuration object
      def setup(config)
        return unless config.enable_tracing

        # Configure the OTLP exporter
        exporter = OpenTelemetry::Exporter::OTLP::Exporter.new(
          endpoint: config.tracing_endpoint,
          headers: config.tracing_headers || {}
        )

        # Configure the SDK
        OpenTelemetry::SDK.configure do |c|
          c.service_name = config.app_name || "ai-agents"
          c.service_version = config.app_version || Agents::VERSION
          c.resource = OpenTelemetry::SDK::Resources::Resource.create(
            "deployment.environment" => config.environment || "production"
          )

          # Use batch span processor for better performance
          c.add_span_processor(
            OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(exporter)
          )
        end

        @tracer = OpenTelemetry.tracer_provider.tracer("ai-agents", Agents::VERSION)
        @enabled = true
      end

      # Check if tracing is enabled
      # @return [Boolean]
      def enabled?
        @enabled ||= false
      end

      # Get the tracer instance
      # @return [OpenTelemetry::Trace::Tracer]
      def tracer
        @tracer ||= OpenTelemetry.tracer_provider.tracer("ai-agents", Agents::VERSION)
      end

      # Get the current trace context from the stack
      # @return [TraceContext, nil]
      def current_trace_context
        trace_context_stack.last
      end

      # Get the current OpenTelemetry span
      # @return [OpenTelemetry::Trace::Span, nil]
      def current_span
        OpenTelemetry::Trace.current_span
      end

      # Get the root span of the current trace (stored when with_trace is called)
      # @return [OpenTelemetry::Trace::Span, nil]
      def root_span
        trace_context_stack.first&.instance_variable_get(:@root_span) || current_span
      end

      # Set trace context for all operations within the block.
      # Contexts can be nested and will be merged intelligently.
      #
      # @param user_id [String, nil] User identifier
      # @param session_id [String, nil] Session identifier
      # @param trace_name [String, nil] Name for the root trace span
      # @param tags [Array<String>, nil] Tags for the trace
      # @param metadata [Hash, nil] Additional metadata
      # @yield Block to execute within the trace context
      # @return The return value of the block
      def with_trace(user_id: nil, session_id: nil, trace_name: nil, tags: nil, metadata: nil)
        # If tracing is disabled, just execute the block
        return yield unless enabled?

        # Create new context, merging with parent if exists
        new_context = TraceContext.new(
          user_id: user_id,
          session_id: session_id,
          trace_name: trace_name,
          tags: tags,
          metadata: metadata
        )

        parent_context = current_trace_context
        merged_context = parent_context ? parent_context.merge(new_context) : new_context

        # Push onto stack
        trace_context_stack.push(merged_context)

        # Create root span with trace attributes
        span_name = merged_context.trace_name || "agent.conversation"
        attributes = merged_context.to_otel_attributes

        tracer.in_span(span_name, attributes: attributes) do |span|
          # Store root span reference in the trace context
          merged_context.instance_variable_set(:@root_span, span)
          yield
        end
      ensure
        trace_context_stack.pop
      end

      # Create a custom span within the current trace.
      #
      # @param name [String] Name of the span
      # @param type [Symbol] Type of observation (:span, :task, :workflow)
      # @param attributes [Hash] Additional span attributes
      # @yield [span] Block to execute within the span
      # @yieldparam span [OpenTelemetry::Trace::Span] The current span
      # @return The return value of the block
      def in_span(name, type: :span, attributes: {})
        # If tracing is disabled, just execute the block
        return yield(NoopSpan.new) unless enabled?

        span_attributes = attributes.dup
        span_attributes["langfuse.observation.type"] = type.to_s

        tracer.in_span(name, attributes: span_attributes) do |span|
          yield(span)
        end
      end

      # Create an agent execution span
      # @private
      def agent_span(agent_name, model:, attributes: {})
        return yield(NoopSpan.new) unless enabled?

        span_attributes = {
          "gen_ai.agent.name" => agent_name,
          "gen_ai.request.model" => model,
          "langfuse.observation.type" => "generation"
        }.merge(attributes)

        # Merge in current trace context attributes
        if (context = current_trace_context)
          span_attributes.merge!(context.to_otel_attributes)
        end

        tracer.in_span("agent.#{agent_name}", attributes: span_attributes) do |span|
          yield(span)
        end
      end

      # Create a tool execution span
      # @private
      def tool_span(tool_name, arguments:, attributes: {})
        return yield(NoopSpan.new) unless enabled?

        span_attributes = {
          "gen_ai.tool.name" => tool_name,
          "tool.input" => JSON.generate(arguments),
          "langfuse.observation.type" => "span"
        }.merge(attributes)

        tracer.in_span("tool.#{tool_name}", attributes: span_attributes) do |span|
          yield(span)
        end
      end

      # Reset tracing state (mainly for testing)
      # @private
      def reset!
        @tracer = nil
        @enabled = false
        Thread.current[:agents_trace_context_stack] = nil
      end

      private

      # Thread-local storage for trace context stack
      def trace_context_stack
        Thread.current[:agents_trace_context_stack] ||= []
      end
    end

    # A no-op span implementation for when tracing is disabled
    class NoopSpan
      def set_attribute(_key, _value); end

      def add_event(_name, _attributes = {}); end

      def set_status(_status); end

      def record_exception(_exception); end
    end
  end
end
