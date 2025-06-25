# frozen_string_literal: true

require "fileutils"
require "json"

module Agents
  module Tracing
    # File exporter for saving traces to disk as JSON files
    class FileExporter
      attr_reader :export_path

      # Initialize file exporter
      # @param export_path [String] Directory path to save traces
      def initialize(export_path)
        @export_path = File.expand_path(export_path)
        ensure_directory_exists
      end

      # Export a trace to a JSON file
      # @param trace [Trace] The trace to export
      # @param format [Symbol] Export format (:json or :otel)
      def export(trace, format: :json)
        return unless trace

        filename = generate_filename(trace, format)
        filepath = File.join(@export_path, filename)

        begin
          content = case format
                   when :otel
                     JSON.pretty_generate({
                       resourceSpans: [
                         {
                           resource: {
                             attributes: {
                               "service.name" => "ruby-agents",
                               "service.version" => "1.0.0"
                             }
                           },
                           scopeSpans: [
                             {
                               scope: {
                                 name: "agents.tracer",
                                 version: "1.0.0"
                               },
                               spans: trace.to_otel_spans
                             }
                           ]
                         }
                       ]
                     })
                   else
                     trace.to_json
                   end
          
          File.write(filepath, content)
        rescue StandardError => e
          warn "Failed to export trace #{trace.trace_id}: #{e.message}"
          raise TracingError, "Trace export failed: #{e.message}"
        end
      end

      private

      # Ensure the export directory exists
      def ensure_directory_exists
        FileUtils.mkdir_p(@export_path) unless Dir.exist?(@export_path)
      rescue StandardError => e
        raise TracingError, "Cannot create trace export directory #{@export_path}: #{e.message}"
      end

      # Generate filename for trace
      # @param trace [Trace] The trace
      # @param format [Symbol] Export format
      # @return [String] Filename
      def generate_filename(trace, format = :json)
        timestamp = trace.start_time ? Time.at(trace.start_time).strftime("%Y%m%d_%H%M%S") : "unknown"
        workflow = trace.workflow_name ? "_#{sanitize_filename(trace.workflow_name)}" : ""
        format_suffix = format == :otel ? "_otel" : ""
        "#{timestamp}#{workflow}_#{trace.trace_id}#{format_suffix}.json"
      end

      # Sanitize filename by removing unsafe characters
      # @param name [String] Name to sanitize
      # @return [String] Sanitized name
      def sanitize_filename(name)
        name.to_s.gsub(/[^a-zA-Z0-9._-]/, "_").gsub(/_+/, "_")
      end
    end
  end
end
