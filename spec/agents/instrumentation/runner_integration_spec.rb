# frozen_string_literal: true

require "webmock/rspec"
require "opentelemetry-sdk"
require_relative "../../../lib/agents"
require_relative "../../../lib/agents/instrumentation"

RSpec.describe Agents::Instrumentation do
  include OpenAITestHelper

  let(:exporter) { OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new }
  let(:provider) do
    OpenTelemetry::SDK::Trace::TracerProvider.new.tap do |tracer_provider|
      tracer_provider.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter))
    end
  end
  let(:runner) do
    specialist = Agents::Agent.new(name: "Specialist", model: "gpt-4o")
    triage = Agents::Agent.new(name: "Triage", model: "gpt-4o", handoff_agents: [specialist])
    Agents::Runner.with_agents(triage, specialist)
  end

  before do
    setup_openai_test_config
    disable_net_connect!
    stub_chat_sequence(
      { tool_calls: [{ name: "handoff_to_specialist", arguments: "{}" }] },
      "The specialist is ready."
    )

    described_class.install(
      runner, tracer: provider.tracer("runner-integration"), trace_name: "test.run",
              span_attributes: { "langfuse.trace.tags" => '["captain_v2"]' },
              attribute_provider: ->(_ctx) { { "langfuse.user.id" => "account_1" } }
    )
  end

  after { allow_net_connect! }

  it "maps a handoff run to one root, two generations, and one tool observation" do
    result = runner.run("Please help", context: { session_id: "conversation_2" })
    spans = exporter.finished_spans
    root = spans.find { |span| span.name == "test.run" }
    generations = spans.select { |span| span.name == "test.run.generation" }
    tool = spans.find { |span| span.name == "test.run.tool.handoff_to_specialist" }

    expect(result.error).to be_nil
    expect(root.attributes).to include("langfuse.observation.input" => "Please help",
                                       "langfuse.observation.output" => "The specialist is ready.")
    expect(generations.size).to eq(2)
    expect(generations.map { |span| span.attributes["gen_ai.usage.input_tokens"] }).to all(be > 0)
    expect(generations.last.attributes).to include("langfuse.user.id" => "account_1",
                                                   "langfuse.session.id" => "conversation_2")
    expect(tool.attributes).to include("langfuse.observation.type" => "tool")
    expect(root.events.map(&:name)).to include("test.run.handoff")
  end
end
