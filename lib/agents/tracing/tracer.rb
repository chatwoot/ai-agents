# frozen_string_literal: true

begin
  require "opentelemetry/sdk"
  require "opentelemetry/exporter/otlp"
rescue LoadError
  # OpenTelemetry gems not available, tracing will be disabled
end

module Agents
  module Tracing
    class Tracer
      attr_reader :otel_tracer

      def initialize(service_name:)
        unless opentelemetry_available?
          raise "OpenTelemetry gems not installed. Add opentelemetry-sdk and opentelemetry-exporter-otlp to your Gemfile"
        end

        @provider = init_tracer_provider(service_name)
        @otel_tracer = @provider.tracer("agents-tracer", Agents::VERSION)
      end

      def shutdown
        @provider.shutdown if @provider
      end

      private

      def opentelemetry_available?
        defined?(OpenTelemetry::SDK)
      end

      def init_tracer_provider(service_name)
        OpenTelemetry::SDK.configure do |c|
          c.service_name = service_name
          c.resource = OpenTelemetry::SDK::Resources::Resource.create({
            'service.name' => service_name,
            'project.name' => service_name # Phoenix expects this
          })
          c.use "OpenTelemetry::Exporter::OTLP"
          # OTLP endpoint from ENV['OTEL_EXPORTER_OTLP_ENDPOINT']
          # Defaults to http://localhost:4318/v1/traces
        end

        OpenTelemetry.tracer_provider
      end
    end
  end
end
