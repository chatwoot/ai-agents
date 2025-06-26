# frozen_string_literal: true

# Tracing and observability components for the Agents SDK
# Provides OpenTelemetry-compatible tracing with support for multiple export formats
# including file export and Jaeger integration for visualization.

require 'json'
require 'net/http'
require 'uri'
require 'securerandom'
require 'time'
require 'fileutils'

module Agents
  module Tracing
    # Represents a single span in a distributed trace
    # Compatible with OpenTelemetry span specification
    class Span
      attr_reader :trace_id, :span_id, :parent_span_id, :name, :kind, :start_time, :end_time, 
                  :attributes, :events, :status, :resource

      def initialize(name:, trace_id: nil, parent_span_id: nil, kind: :internal, resource: {})
        @trace_id = trace_id || generate_trace_id
        @span_id = generate_span_id
        @parent_span_id = parent_span_id
        @name = name
        @kind = kind
        @start_time = Time.now.utc
        @end_time = nil
        @attributes = {}
        @events = []
        @status = { code: :ok }
        @resource = resource.merge(default_resource)
      end

      # Set an attribute on the span
      def set_attribute(key, value)
        @attributes[key.to_s] = value
        self
      end

      # Add an event to the span
      def add_event(name, attributes: {}, timestamp: nil)
        @events << {
          name: name,
          timestamp: (timestamp || Time.now.utc),
          attributes: attributes
        }
        self
      end

      # Set the span status
      def set_status(code:, description: nil)
        @status = { code: code }
        @status[:description] = description if description
        self
      end

      # Finish the span
      def finish(end_time: nil)
        @end_time = end_time || Time.now.utc
        self
      end

      # Check if span is finished
      def finished?
        !@end_time.nil?
      end

      # Convert to OpenTelemetry JSON format
      def to_otel_json
        {
          traceId: @trace_id,
          spanId: @span_id,
          parentSpanId: @parent_span_id,
          name: @name,
          kind: span_kind_to_int(@kind),
          startTimeUnixNano: time_to_nanoseconds(@start_time).to_s,
          endTimeUnixNano: (@end_time ? time_to_nanoseconds(@end_time) : time_to_nanoseconds(Time.now.utc)).to_s,
          attributes: attributes_to_otel_format(@attributes),
          events: events_to_otel_format(@events),
          status: format_status(@status)
        }.compact
      end

      private

      def generate_trace_id
        SecureRandom.hex(16)
      end

      def generate_span_id
        SecureRandom.hex(8)
      end

      def default_resource
        {
          'service.name' => determine_service_name,
          'service.version' => Agents::VERSION,
          'telemetry.sdk.name' => 'ruby-agents-sdk',
          'telemetry.sdk.language' => 'ruby',
          'telemetry.sdk.version' => Agents::VERSION
        }
      end

      def determine_service_name
        # Use the base service name - detailed naming happens in export
        Agents.configuration.tracing.service_name
      end

      def span_kind_to_int(kind)
        case kind
        when :internal then 1
        when :server then 2
        when :client then 3
        when :producer then 4
        when :consumer then 5
        else 0 # unspecified
        end
      end

      def time_to_nanoseconds(time)
        (time.to_f * 1_000_000_000).to_i
      end

      def attributes_to_otel_format(attrs)
        attrs.map do |key, value|
          {
            key: key.to_s,
            value: format_attribute_value(value)
          }
        end
      end

      def format_attribute_value(value)
        case value
        when String
          { stringValue: value }
        when Integer
          { intValue: value }
        when Float
          { doubleValue: value }
        when TrueClass, FalseClass
          { boolValue: value }
        else
          { stringValue: value.to_s }
        end
      end

      def events_to_otel_format(events)
        events.map do |event|
          {
            timeUnixNano: time_to_nanoseconds(event[:timestamp]).to_s,
            name: event[:name],
            attributes: attributes_to_otel_format(event[:attributes] || {})
          }
        end
      end

      def format_status(status)
        code = case status[:code]
               when :ok then 1
               when :error then 2
               else 0 # unset
               end
        
        result = { code: code }
        result[:description] = status[:description] if status[:description]
        result
      end
    end

    # Main tracer class for creating and managing spans
    class Tracer
      def initialize
        @current_spans = {}
        @trace_buffers = {} # Buffer spans by trace_id until root span finishes
        @root_spans = {} # Track root spans by thread to determine when to export
      end

      # Start a new span
      def start_span(name, kind: :internal, parent: nil, **attributes)
        thread_id = Thread.current.object_id
        parent_span_id = parent ? parent.span_id : current_span&.span_id
        trace_id = parent&.trace_id || current_span&.trace_id

        span = Span.new(
          name: name,
          trace_id: trace_id,
          parent_span_id: parent_span_id,
          kind: kind
        )

        # Set attributes
        attributes.each { |key, value| span.set_attribute(key, value) }

        # Set as current span for this thread
        @current_spans[thread_id] = span
        
        # Track root spans (spans with no parent)
        if parent_span_id.nil?
          @root_spans[thread_id] = span
        end

        span
      end

      # Get the current active span for this thread
      def current_span
        thread_id = Thread.current.object_id
        @current_spans[thread_id]
      end

      # Execute a block within a span context
      def in_span(name, kind: :internal, **attributes, &block)
        thread_id = Thread.current.object_id
        parent_span = current_span
        span = start_span(name, kind: kind, **attributes)
        is_root_span = span.parent_span_id.nil?
        
        begin
          result = block.call(span)
          span.set_status(code: :ok)
          result
        rescue => e
          span.set_status(code: :error, description: e.message)
          span.add_event('exception', attributes: {
            'exception.type' => e.class.name,
            'exception.message' => e.message,
            'exception.stacktrace' => e.backtrace&.join("\n")
          })
          raise
        ensure
          span.finish
          
          # Buffer span for later export
          if Agents.configuration.tracing.enabled
            buffer_span(span)
            
            # If this is the root span finishing, export the complete trace
            if is_root_span
              export_complete_trace(span.trace_id)
              @root_spans.delete(thread_id)
            end
          end
          
          # Restore the parent span as current (proper span stack management)
          if parent_span
            @current_spans[thread_id] = parent_span
          else
            @current_spans.delete(thread_id)
          end
        end
      end

      private

      def buffer_span(span)
        trace_id = span.trace_id
        @trace_buffers[trace_id] ||= []
        @trace_buffers[trace_id] << span
      end

      def export_complete_trace(trace_id)
        spans = @trace_buffers.delete(trace_id)
        return unless spans&.any?
        
        # Sort spans by start time for better visualization
        spans.sort_by! { |span| span.start_time }
        
        Exporter.export(spans)
      end
    end

    # Base exporter class
    class Exporter
      def self.export(spans)
        config = Agents.configuration.tracing
        return unless config.enabled

        exporters = []
        
        # File exporter
        if config.export_path
          exporters << FileExporter.new(config.export_path, config.otel_format)
        end

        # Jaeger exporter  
        if config.jaeger_endpoint
          exporters << JaegerExporter.new(config.jaeger_endpoint)
        end

        # Console exporter
        if config.console_output
          exporters << ConsoleExporter.new
        end

        exporters.each do |exporter|
          begin
            exporter.export(spans)
          rescue => e
            warn "Failed to export traces: #{e.message}" if Agents.configuration.debug
          end
        end
      end
    end

    # Exports traces to files in OpenTelemetry format
    class FileExporter
      def initialize(export_path, otel_format = true)
        @export_path = export_path
        @otel_format = otel_format
        ensure_directory_exists
      end

      def export(spans)
        return if spans.empty?

        if @otel_format
          export_otel_format(spans)
        else
          export_simple_format(spans)
        end
      end

      private

      def ensure_directory_exists
        FileUtils.mkdir_p(@export_path) unless Dir.exist?(@export_path)
      end

      def format_resource(resource)
        {
          attributes: resource.map do |key, value|
            {
              key: key.to_s,
              value: format_attribute_value(value)
            }
          end
        }
      end

      # Use service name from the first span's resource
      def format_resource_with_context(resource, spans)
        format_resource(resource)
      end

      def format_attribute_value(value)
        case value
        when String
          { stringValue: value }
        when Integer
          { intValue: value }
        when Float
          { doubleValue: value }
        when TrueClass, FalseClass
          { boolValue: value }
        else
          { stringValue: value.to_s }
        end
      end

      def export_otel_format(spans)
        # Group spans by trace_id
        traces_by_id = spans.group_by(&:trace_id)
        
        traces_by_id.each do |trace_id, trace_spans|
          # OpenTelemetry JSON format
          otel_data = {
            file_format: "1.0.0",
            schema_url: "https://opentelemetry.io/schemas/1.7.0",
            resourceSpans: [
              {
                schemaUrl: "https://opentelemetry.io/schemas/1.7.0",
                resource: format_resource_with_context(trace_spans.first.resource, trace_spans),
                scopeSpans: [
                  {
                    scope: {},
                    schemaUrl: "https://opentelemetry.io/schemas/1.7.0",
                    spans: trace_spans.map(&:to_otel_json)
                  }
                ]
              }
            ]
          }

          filename = "trace_#{trace_id}_#{Time.now.to_i}.json"
          filepath = File.join(@export_path, filename)
          File.write(filepath, JSON.pretty_generate(otel_data))
        end
      end

      def export_simple_format(spans)
        spans.each do |span|
          filename = "span_#{span.span_id}_#{Time.now.to_i}.json"
          File.write(File.join(@export_path, filename), JSON.pretty_generate(span.to_otel_json))
        end
      end
    end

    # Exports traces to Jaeger
    class JaegerExporter
      def initialize(endpoint)
        @endpoint = URI(endpoint)
      end

      def export(spans)
        return if spans.empty?

        # Convert to Jaeger format and send
        jaeger_data = convert_to_jaeger_format(spans)
        send_to_jaeger(jaeger_data)
      end

      private

      def convert_to_jaeger_format(spans)
        # Group spans by trace_id
        traces_by_id = spans.group_by(&:trace_id)
        
        {
          data: traces_by_id.map do |trace_id, trace_spans|
            {
              traceID: trace_id,
              spans: trace_spans.map do |span|
                {
                  traceID: span.trace_id,
                  spanID: span.span_id,
                  parentSpanID: span.parent_span_id,
                  operationName: span.name,
                  startTime: (span.start_time.to_f * 1_000_000).to_i, # microseconds
                  duration: span.finished? ? ((span.end_time - span.start_time) * 1_000_000).to_i : 0,
                  tags: span.attributes.map { |k, v| { key: k, value: v.to_s } },
                  process: {
                    serviceName: span.resource['service.name'],
                    tags: span.resource.map { |k, v| { key: k, value: v.to_s } }
                  }
                }
              end
            }
          end
        }
      end

      def send_to_jaeger(data)
        http = Net::HTTP.new(@endpoint.host, @endpoint.port)
        http.use_ssl = @endpoint.scheme == 'https'
        
        request = Net::HTTP::Post.new(@endpoint.path)
        request['Content-Type'] = 'application/json'
        request.body = JSON.generate(data)
        
        response = http.request(request)
        
        unless response.code.start_with?('2')
          raise "Jaeger export failed: #{response.code} #{response.message}"
        end
      end
    end

    # Exports traces to console for debugging
    class ConsoleExporter
      def export(spans)
        spans.each do |span|
          puts "=== TRACE SPAN ==="
          puts "Trace ID: #{span.trace_id}"
          puts "Span ID: #{span.span_id}"
          puts "Parent: #{span.parent_span_id}"
          puts "Name: #{span.name}"
          puts "Duration: #{span.finished? ? (span.end_time - span.start_time).round(3) : 'ongoing'}s"
          puts "Attributes: #{span.attributes}" unless span.attributes.empty?
          puts "Events: #{span.events.size}" unless span.events.empty?
          puts "Status: #{span.status}"
          puts
        end
      end
    end

    # Global tracer instance
    def self.tracer
      @tracer ||= Tracer.new
    end

    # Convenience method for creating spans
    def self.in_span(name, **options, &block)
      tracer.in_span(name, **options, &block)
    end
  end
end