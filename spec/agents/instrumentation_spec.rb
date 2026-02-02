# frozen_string_literal: true

require_relative "../../lib/agents"
require_relative "../../lib/agents/instrumentation"

# Stub OTel classes since the gem is optional and not loaded in tests
module OpenTelemetry
  module Trace
    class Tracer; end
  end
end

RSpec.describe Agents::Instrumentation do
  describe ".otel_available?" do
    it "returns false when opentelemetry-api is not installed" do
      allow(described_class).to receive(:require).with("opentelemetry-api").and_raise(LoadError)
      expect(described_class.otel_available?).to be false
    end
  end

  describe ".install" do
    context "when opentelemetry-api is not available" do
      it "returns nil" do
        allow(described_class).to receive(:otel_available?).and_return(false)

        agent = Agents::Agent.new(name: "Test", instructions: "test")
        runner = Agents::Runner.with_agents(agent)
        tracer = instance_double(OpenTelemetry::Trace::Tracer)

        result = described_class.install(runner, tracer: tracer)
        expect(result).to be_nil
      end
    end

    context "when opentelemetry-api is available" do
      let(:tracer) { instance_double(OpenTelemetry::Trace::Tracer) }
      let(:agent) { Agents::Agent.new(name: "Test", instructions: "test") }
      let(:runner) { Agents::Runner.with_agents(agent) }

      before do
        allow(described_class).to receive(:otel_available?).and_return(true)
      end

      it "registers all callback handlers on the runner" do
        result = described_class.install(runner, tracer: tracer)

        expect(result).to eq(runner)
      end

      it "passes span_attributes and attribute_provider to TracingCallbacks" do
        span_attrs = { "langfuse.trace.tags" => '["v2"]' }
        provider = ->(_ctx) { { "langfuse.user.id" => "123" } }

        allow(Agents::Instrumentation::TracingCallbacks).to receive(:new).and_call_original

        described_class.install(runner, tracer: tracer, span_attributes: span_attrs, attribute_provider: provider)

        expect(Agents::Instrumentation::TracingCallbacks).to have_received(:new).with(
          tracer: tracer,
          span_attributes: span_attrs,
          attribute_provider: provider
        )
      end
    end
  end
end
