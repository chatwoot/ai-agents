# frozen_string_literal: true

require "active_support"
require "active_support/notifications"
require "base64"
require "json"
require "net/http"
require "opentelemetry-sdk"
require "opentelemetry-exporter-otlp"
require "webmock/rspec"
require_relative "../../lib/agents/instrumentation"

class FailingLookupTool < Agents::Tool
  def name = "failing_lookup"
  def description = "Raise a test error"

  def perform(_tool_context)
    raise "Synthetic lookup failure"
  end
end

RSpec.describe "Langfuse export", :langfuse_e2e do # rubocop:disable RSpec/DescribeClass
  include OpenAITestHelper

  let(:host) { ENV.fetch("LANGFUSE_HOST") }
  let(:auth) { Base64.strict_encode64("#{ENV.fetch("LANGFUSE_PUBLIC_KEY")}:#{ENV.fetch("LANGFUSE_SECRET_KEY")}") }
  let(:exporter) { OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new }
  let(:trace_name) { "ai-agents.rubyllm-2.e2e" }
  let(:session_id) { "ai_agents_e2e_#{SecureRandom.hex(8)}" }
  let(:events) { [] }
  let(:original_instrumenter) { RubyLLM.config.instrumenter }
  let(:subscription) do
    ActiveSupport::Notifications.subscribe(/\A(?:chat|tool_call|usage)\.ruby_llm\z/) do |event|
      events << event.name
    end
  end

  before do
    setup_openai_test_config
    original_instrumenter
    RubyLLM.configure { |config| config.instrumenter = ActiveSupport::Notifications }
    subscription
    stub_chat_sequence(
      { tool_calls: [{ name: "handoff_to_specialist", arguments: "{}" }] },
      "The specialist is ready."
    )
    WebMock.allow_net_connect!
  end

  after do
    ActiveSupport::Notifications.unsubscribe(subscription)
    RubyLLM.configure { |config| config.instrumenter = original_instrumenter }
    WebMock.disable_net_connect!
  end

  it "stores runner spans and RubyLLM events in the Langfuse project" do # rubocop:disable RSpec/ExampleLength
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    provider.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter))
    provider.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(otlp_exporter))
    specialist = Agents::Agent.new(name: "Specialist", model: "gpt-4o")
    triage = Agents::Agent.new(name: "Triage", model: "gpt-4o", handoff_agents: [specialist])
    runner = Agents::Runner.with_agents(triage, specialist)
    instrument(runner, provider, trace_name)

    result = runner.run("Please help", context: { session_id: session_id })
    provider.force_flush
    trace_id = exporter.finished_spans.first.hex_trace_id
    observations = wait_for_observations(trace_id, expected: 6) do |stored|
      stored.any? do |observation|
        observation["name"] == trace_name && observation["input"] == "Please help" &&
          observation["output"] == "The specialist is ready."
      end
    end
    root = observations.find { |observation| observation["name"] == trace_name }
    generations = observations.select { |observation| observation["type"] == "GENERATION" }

    expect(result.error).to be_nil
    expect(events.tally).to include("chat.ruby_llm" => 2, "tool_call.ruby_llm" => 1)
    expect(events).to include("usage.ruby_llm")
    expect(observations.map { |observation| observation["name"] }).to include(
      trace_name, "#{trace_name}.tool.handoff_to_specialist"
    )
    expect(generations.size).to eq(2)
    expect(generations.map { |observation| observation["inputUsage"] }).to all(be > 0)
    expect(generations).to all(satisfy do |observation|
      Time.iso8601(observation["endTime"]) > Time.iso8601(observation["startTime"])
    end)
    expect(observations).to all(include("sessionId" => session_id, "userId" => "ai-agents-e2e"))
    expect(root).to include("input" => "Please help", "output" => "The specialist is ready.")
    expect(root["tags"]).to include("ai-agents-e2e")
  end

  it "stores failed tool and root observations as errors" do
    stub_chat_sequence({ tool_calls: [{ name: "failing_lookup", arguments: "{}" }] })
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    provider.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter))
    provider.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(otlp_exporter))
    agent = Agents::Agent.new(name: "Lookup", model: "gpt-4o", tools: [FailingLookupTool.new])
    runner = Agents::Runner.with_agents(agent)
    instrument(runner, provider, "#{trace_name}.error")

    result = runner.run("Try the lookup", context: { session_id: session_id })
    provider.force_flush
    observations = wait_for_observations(exporter.finished_spans.first.hex_trace_id, expected: 4)

    expect(result.error.message).to eq("Synthetic lookup failure")
    expect(observations.select { |observation| observation["level"] == "ERROR" }
                       .map { |observation| observation["type"] }).to contain_exactly("SPAN", "TOOL")
    expect(events).to include("tool_call.ruby_llm", "usage.ruby_llm")
  end

  def instrument(runner, provider, name)
    Agents::Instrumentation.install(
      runner, tracer: provider.tracer("langfuse-e2e"), trace_name: name,
              span_attributes: { "langfuse.trace.tags" => '["ai-agents-e2e"]' },
              attribute_provider: ->(_ctx) { { "langfuse.user.id" => "ai-agents-e2e" } }
    )
  end

  def otlp_exporter
    OpenTelemetry::Exporter::OTLP::Exporter.new(
      endpoint: "#{host}/api/public/otel/v1/traces",
      headers: { "Authorization" => "Basic #{auth}", "x-langfuse-ingestion-version" => "4" }
    )
  end

  def wait_for_observations(trace_id, expected:)
    20.times do
      observations = fetch_observations(trace_id)
      return observations if observations.size >= expected && (!block_given? || yield(observations))

      sleep 1
    end
    raise "Langfuse did not store #{expected} observations for #{trace_id}"
  end

  def fetch_observations(trace_id)
    uri = observations_uri(trace_id)
    request = Net::HTTP::Get.new(uri)
    request["Authorization"] = "Basic #{auth}"
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") { |http| http.request(request) }
    raise "Langfuse read failed: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body).fetch("data")
  end

  def observations_uri(trace_id)
    uri = URI("#{host}/api/public/v2/observations")
    uri.query = URI.encode_www_form(traceId: trace_id, fields: "core,basic,io,usage,trace_context", limit: 20,
                                    fromStartTime: (Time.now.utc - 60).iso8601,
                                    toStartTime: (Time.now.utc + 60).iso8601)
    uri
  end
end
