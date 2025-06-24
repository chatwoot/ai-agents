# frozen_string_literal: true

require "securerandom"
require "json"
require "time"
require "fileutils"
require "singleton"

module Agents
  module Tracing
    # Tracing errors
    class TracingError < Agents::Error; end

    # Global singleton tracer for managing traces and spans
    class Tracer
      include Singleton

      def initialize
        @exporters = []
        @thread_contexts = {}
      end

      # Start a new trace with optional metadata
      # @param workflow_name [String] Name of the workflow/operation
      # @param metadata [Hash] Additional trace metadata
      # @return [Trace] The started trace
      def start_trace(workflow_name: nil, metadata: {})
        return unless tracing_enabled?

        trace_id = generate_trace_id
        trace = Trace.new(
          trace_id: trace_id,
          workflow_name: workflow_name,
          metadata: metadata,
          start_time: current_time
        )

        set_current_trace(trace)
        trace
      end

      # End the current trace
      # @return [Trace, nil] The ended trace
      def end_trace
        return unless tracing_enabled?

        trace = current_trace
        return nil unless trace

        trace.end_time = current_time
        trace.duration_ms = ((trace.end_time - trace.start_time) * 1000).round(2)

        # Export the completed trace
        export_trace(trace)

        # Clear current trace context
        clear_current_trace
        trace
      end

      # Start a new span under the current trace
      # @param name [String] Span name (e.g., "Agent:TriageAgent", "Tool:GetWeather")
      # @param category [Symbol] Span category (:agent, :tool, :mcp, :handoff, :runner, :context_update)
      # @param metadata [Hash] Additional span metadata
      # @return [Span] The started span
      def start_span(name:, category:, metadata: {})
        return NullSpan.new unless tracing_enabled?

        trace = current_trace
        return NullSpan.new unless trace

        span_id = generate_span_id
        parent_span = current_span

        span = Span.new(
          span_id: span_id,
          trace_id: trace.trace_id,
          parent_id: parent_span&.span_id,
          name: name,
          category: category,
          metadata: metadata,
          start_time: current_time
        )

        # Add span to trace
        trace.add_span(span)

        # Set as current span (push onto stack)
        push_current_span(span)
        span
      end

      # End the current span
      # @param status [Symbol] Span status (:ok, :error)
      # @param result [Object] Span result data
      # @param error [Exception] Error if status is :error
      # @return [Span, nil] The ended span
      def end_span(status: :ok, result: nil, error: nil)
        return unless tracing_enabled?

        span = current_span
        return nil unless span

        span.end_time = current_time
        span.duration_ms = ((span.end_time - span.start_time) * 1000).round(2)
        span.status = status

        span.metadata[:result] = truncate_data(result) if result && should_include_sensitive_data?

        if error
          span.metadata[:error] = {
            class: error.class.name,
            message: error.message,
            backtrace: error.backtrace&.first(5)
          }
        end

        # Pop span from stack
        pop_current_span
        span
      end

      # Execute a block within a span
      # @param name [String] Span name
      # @param category [Symbol] Span category
      # @param metadata [Hash] Additional span metadata
      # @yield Block to execute within the span
      # @return [Object] Block result
      def with_span(name:, category:, metadata: {})
        start_span(name: name, category: category, metadata: metadata)

        begin
          result = yield
          end_span(status: :ok, result: result)
          result
        rescue StandardError => e
          end_span(status: :error, error: e)
          raise
        end
      end

      # Execute a block within a trace
      # @param workflow_name [String] Name of the workflow
      # @param metadata [Hash] Additional trace metadata
      # @yield Block to execute within the trace
      # @return [Object] Block result
      def with_trace(workflow_name: nil, metadata: {})
        existing_trace = current_trace

        # If already in a trace, just yield without creating a new one
        return yield if existing_trace

        trace = start_trace(workflow_name: workflow_name, metadata: metadata)

        begin
          result = yield
          end_trace
          result
        rescue StandardError => e
          if trace&.metadata
            trace.metadata[:error] = {
              class: e.class.name,
              message: e.message
            }
          end
          end_trace
          raise
        end
      end

      # Get the current trace for this thread
      # @return [Trace, nil] Current trace
      def current_trace
        thread_context[:trace]
      end

      # Get the current span for this thread
      # @return [Span, nil] Current span
      def current_span
        spans = thread_context[:span_stack]
        spans&.last
      end

      # Add a trace exporter
      # @param exporter [Object] Exporter that responds to #export(trace)
      def add_exporter(exporter)
        @exporters << exporter
      end

      private

      # Check if tracing is enabled in configuration
      # @return [Boolean] True if tracing is enabled
      def tracing_enabled?
        Agents.configuration.respond_to?(:tracing) &&
          Agents.configuration.tracing.respond_to?(:enabled) &&
          Agents.configuration.tracing.enabled
      end

      # Check if sensitive data should be included in spans
      # @return [Boolean] True if sensitive data should be included
      def should_include_sensitive_data?
        return true unless Agents.configuration.respond_to?(:tracing)
        return true unless Agents.configuration.tracing.respond_to?(:include_sensitive_data)

        Agents.configuration.tracing.include_sensitive_data
      end

      # Generate a unique trace ID
      # @return [String] Trace ID in format "trace_<32_alphanumeric>"
      def generate_trace_id
        "trace_#{SecureRandom.hex(16)}"
      end

      # Generate a unique span ID
      # @return [String] Span ID in format "span_<16_alphanumeric>"
      def generate_span_id
        "span_#{SecureRandom.hex(8)}"
      end

      # Get current high-resolution timestamp
      # @return [Float] Current time as float
      def current_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # Get thread-local context
      # @return [Hash] Thread context
      def thread_context
        thread_id = Thread.current.object_id
        @thread_contexts[thread_id] ||= {
          trace: nil,
          span_stack: []
        }
      end

      # Set current trace for this thread
      # @param trace [Trace] Trace to set as current
      def set_current_trace(trace)
        thread_context[:trace] = trace
      end

      # Clear current trace for this thread
      def clear_current_trace
        context = thread_context
        context[:trace] = nil
        context[:span_stack].clear
      end

      # Push span onto current span stack
      # @param span [Span] Span to push
      def push_current_span(span)
        thread_context[:span_stack] << span
      end

      # Pop span from current span stack
      # @return [Span, nil] Popped span
      def pop_current_span
        thread_context[:span_stack].pop
      end

      # Export trace using all registered exporters
      # @param trace [Trace] Trace to export
      def export_trace(trace)
        @exporters.each do |exporter|
          exporter.export(trace)
        rescue StandardError => e
          warn "Trace export failed: #{e.message}"
        end
      end

      # Truncate data for storage (to prevent huge spans)
      # @param data [Object] Data to truncate
      # @param max_length [Integer] Maximum length for string data
      # @return [Object] Truncated data
      def truncate_data(data, max_length = 1000)
        case data
        when String
          data.length > max_length ? "#{data[0...max_length]}... [truncated]" : data
        when Hash
          data.transform_values { |v| truncate_data(v, max_length) }
        when Array
          data.size > 10 ? data.first(10) + ["... [truncated]"] : data.map { |v| truncate_data(v, max_length) }
        else
          data
        end
      end
    end

    # Trace represents a complete workflow execution
    class Trace
      attr_accessor :trace_id, :workflow_name, :metadata, :start_time, :end_time, :duration_ms
      attr_reader :spans

      def initialize(trace_id:, workflow_name: nil, metadata: {}, start_time: nil)
        @trace_id = trace_id
        @workflow_name = workflow_name
        @metadata = metadata || {}
        @start_time = start_time
        @end_time = nil
        @duration_ms = nil
        @spans = []
      end

      # Add a span to this trace
      # @param span [Span] Span to add
      def add_span(span)
        @spans << span
      end

      # Convert trace to JSON-serializable hash
      # @return [Hash] JSON-serializable representation
      def to_h
        {
          trace_id: @trace_id,
          workflow_name: @workflow_name,
          start_time: @start_time ? Time.at(@start_time).utc.iso8601(3) : nil,
          end_time: @end_time ? Time.at(@end_time).utc.iso8601(3) : nil,
          duration_ms: @duration_ms,
          metadata: @metadata,
          spans: @spans.map(&:to_h)
        }
      end

      # Convert trace to JSON
      # @return [String] JSON representation
      def to_json(*args)
        JSON.pretty_generate(to_h, *args)
      end
    end

    # Span represents a single operation within a trace
    class Span
      attr_accessor :span_id, :trace_id, :parent_id, :name, :category, :metadata,
                    :start_time, :end_time, :duration_ms, :status

      def initialize(span_id:, trace_id:, name:, category:, parent_id: nil, metadata: {}, start_time: nil)
        @span_id = span_id
        @trace_id = trace_id
        @parent_id = parent_id
        @name = name
        @category = category
        @metadata = metadata || {}
        @start_time = start_time
        @end_time = nil
        @duration_ms = nil
        @status = :ok
      end

      # Convert span to JSON-serializable hash
      # @return [Hash] JSON-serializable representation
      def to_h
        {
          span_id: @span_id,
          trace_id: @trace_id,
          parent_id: @parent_id,
          name: @name,
          category: @category.to_s,
          start_time: @start_time ? Time.at(@start_time).utc.iso8601(3) : nil,
          end_time: @end_time ? Time.at(@end_time).utc.iso8601(3) : nil,
          duration_ms: @duration_ms,
          status: @status.to_s,
          metadata: @metadata
        }
      end
    end

    # Null object pattern for when tracing is disabled
    class NullSpan
      def method_missing(_method_name, *_args, **_kwargs)
        # Return self to allow chaining
        self
      end

      def respond_to_missing?(_method_name, _include_private = false)
        true
      end

      def span_id
        nil
      end

      def to_h
        {}
      end
    end

    # Module methods for convenient access to singleton tracer
    module_function

    # Access to singleton tracer instance
    # @return [Tracer] Singleton tracer
    def tracer
      Tracer.instance
    end

    # Start a trace (delegates to tracer)
    def start_trace(**args)
      tracer.start_trace(**args)
    end

    # End current trace (delegates to tracer)
    def end_trace
      tracer.end_trace
    end

    # Start a span (delegates to tracer)
    def start_span(**args)
      tracer.start_span(**args)
    end

    # End current span (delegates to tracer)
    def end_span(**args)
      tracer.end_span(**args)
    end

    # Execute block within a span (delegates to tracer)
    def with_span(**args, &block)
      tracer.with_span(**args, &block)
    end

    # Execute block within a trace (delegates to tracer)
    def with_trace(**args, &block)
      tracer.with_trace(**args, &block)
    end

    # Get current trace (delegates to tracer)
    def current_trace
      tracer.current_trace
    end

    # Get current span (delegates to tracer)
    def current_span
      tracer.current_span
    end
  end
end
