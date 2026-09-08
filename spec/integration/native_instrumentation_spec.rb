# frozen_string_literal: true

require "webmock/rspec"
require "agents/instrumentation"
require "opentelemetry-sdk"

RSpec.describe Agents::Instrumentation do
  include OpenAITestHelper

  let(:exporter) { OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new }
  let(:provider) do
    OpenTelemetry::SDK::Trace::TracerProvider.new.tap do |provider|
      provider.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter))
    end
  end

  before do
    setup_openai_test_config
    disable_net_connect!
  end

  after do
    provider.shutdown
    allow_net_connect!
  end

  it "exports one generation per request across handoffs with the correct parents and metadata" do
    specialist = Agents::Agent.new(name: "Specialist", model: "gpt-4o-mini")
    triage = Agents::Agent.new(name: "Triage", model: "gpt-4o", handoff_agents: [specialist])
    runner = Agents::Runner.with_agents(triage, specialist)
    described_class.install(runner, tracer: provider.tracer("test"))
    stub_chat_sequence({ tool_calls: [{ name: "handoff_to_specialist", arguments: {} }] }, "Done")

    result = runner.run("Help", context: { session_id: "conversation_1" })

    expect(result.error).to be_nil
    spans = exporter.finished_spans
    generations = spans.select { |span| span.name == "agents.run.generation" }
    expect(generations.size).to eq(2)
    expect(generations.map { |span| span.attributes["gen_ai.request.model"] }).to eq(%w[gpt-4o gpt-4o-mini])
    root = spans.find { |span| span.name == "agents.run" }
    expect(root.attributes).to include("langfuse.trace.input" => "Help", "langfuse.observation.input" => "Help",
                                       "langfuse.trace.output" => "Done", "langfuse.observation.output" => "Done")
    expect(spans.reject { |span| generations.include?(span) }.none? do |span|
      span.attributes.key?("gen_ai.request.model")
    end).to be true
    generations.each do |generation|
      parent = spans.find { |span| span.span_id == generation.parent_span_id }
      expect(parent.name).to start_with("agents.run.agent.")
      expect(generation.attributes["langfuse.session.id"]).to eq("conversation_1")
      expect(generation.end_timestamp).to be > generation.start_timestamp
    end
    last_input = JSON.parse(generations.last.attributes["langfuse.observation.input"])
    expect(last_input.last["role"]).to eq("tool")
    expect(result.context).not_to have_key(:__otel_tracing)
  end
end
