# frozen_string_literal: true

require_relative "../../lib/agents"
require_relative "../../lib/agents/instrumentation"

# Stub OTel classes since the gem is optional and not loaded in tests
module OpenTelemetry
  module Trace
    class Tracer; end
    class Span; end
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
      let(:root_span) { instance_double(OpenTelemetry::Trace::Span, add_event: nil) }
      let(:context_wrapper) do
        Agents::RunContext.new({ __otel_tracing: { root_span: root_span } })
      end
      let(:handoff_callback_manager) do
        callback = runner.instance_variable_get(:@callbacks).fetch(:agent_handoff).first
        Agents::CallbackManager.new(agent_handoff: [callback])
      end

      before do
        allow(described_class).to receive(:otel_available?).and_return(true)
      end

      it "registers all callback handlers on the runner" do
        result = described_class.install(runner, tracer: tracer)

        expect(result).to eq(runner)
      end

      it "is idempotent per runner and does not register tracing twice" do
        allow(Agents::Instrumentation::TracingCallbacks).to receive(:new).and_call_original

        first = described_class.install(runner, tracer: tracer)
        second = described_class.install(runner, tracer: tracer)

        expect(first).to eq(runner)
        expect(second).to eq(runner)
        expect(Agents::Instrumentation::TracingCallbacks).to have_received(:new).once
      end

      it "maps traced events to valid runner callback methods" do
        traced_events = described_class.send(:const_get, :TRACED_EVENTS)

        traced_events.each do |event|
          expect(runner).to respond_to(:"on_#{event}")
        end
      end

      it "keeps handoff tracing compatible when metadata is emitted" do
        described_class.install(runner, tracer: tracer)

        expect do
          handoff_callback_manager.emit_agent_handoff(
            "Triage",
            "Billing",
            "capability_match",
            context_wrapper,
            { customer_message: "do not export me" }
          )
        end.not_to output(/Callback error/).to_stderr

        expect(root_span).to have_received(:add_event).with(
          "agents.run.handoff",
          attributes: {
            "handoff.from" => "Triage",
            "handoff.to" => "Billing",
            "handoff.reason" => "capability_match"
          }
        )
      end
    end
  end
end
