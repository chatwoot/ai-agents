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
      def export(trace)
        return unless trace

        filename = generate_filename(trace)
        filepath = File.join(@export_path, filename)

        begin
          File.write(filepath, trace.to_json)
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
      # @return [String] Filename
      def generate_filename(trace)
        timestamp = trace.start_time ? Time.at(trace.start_time).strftime("%Y%m%d_%H%M%S") : "unknown"
        workflow = trace.workflow_name ? "_#{sanitize_filename(trace.workflow_name)}" : ""
        "#{timestamp}#{workflow}_#{trace.trace_id}.json"
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
