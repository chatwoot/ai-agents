# frozen_string_literal: true

require "spec_helper"
require "agents/instrumentation"
require "opentelemetry-sdk"

# rubocop:disable Naming/MethodParameterName
unless defined?(AddNumbersTool)
  class AddNumbersTool < Agents::Tool
    param :a, type: "integer", desc: "First addend"
    param :b, type: "integer", desc: "Second addend"

    def name
      "add_numbers"
    end

    def description
      "Add two integers"
    end

    def perform(_tool_context, a:, b:)
      a + b
    end
  end
end
# rubocop:enable Naming/MethodParameterName

# rubocop:disable RSpec/DescribeClass
RSpec.describe "Live instrumentation smoke test", :live_llm do
  include LiveLLMHelper

  let(:model) { live_model }
  let(:in_memory_exporter) { OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new }

  before do
    configure_live_llm(model: ENV.fetch("OPENAI_MODEL", LiveLLMHelper::DEFAULT_LIVE_MODEL))
    configure_otel(in_memory_exporter)
  end

  context "with tool-calling agent" do
    # rubocop:disable RSpec/InstanceVariable
    before do
      tracer = OpenTelemetry.tracer_provider.tracer("live-instrumentation-test")

      agent = Agents::Agent.new(
        name: "Calculator",
        instructions: "Use the add_numbers tool to add 2 and 3. " \
                      "Call the tool exactly once. Return only the numeric result.",
        model: model,
        tools: [AddNumbersTool.new],
        temperature: 0
      )

      runner = Agents::Runner.with_agents(agent)
      Agents::Instrumentation.install(runner, tracer: tracer, trace_name: "smoke-test")

      @run_result = runner.run("Add 2 and 3.")
      OpenTelemetry.tracer_provider.force_flush
    end

    it "completes the conversation successfully" do
      expect(@run_result.error).to be_nil
      expect(@run_result.output.to_s.strip).to include("5")
      log_langfuse_status("smoke-test")
    end
    # rubocop:enable RSpec/InstanceVariable

    it "produces a root span with trace I/O and no model attribute" do
      root = find_span("smoke-test")
      expect(root).not_to be_nil

      attrs = root.attributes
      expect(attrs["langfuse.trace.input"]).not_to be_nil
      expect(attrs["langfuse.trace.output"]).not_to be_nil
      expect(attrs["langfuse.observation.input"]).not_to be_nil
      expect(attrs["langfuse.observation.output"]).not_to be_nil
      expect(attrs).not_to have_key("gen_ai.request.model")
    end

    it "produces generation spans with model and token usage" do
      gen_spans = in_memory_exporter.finished_spans.select { |s| s.name == "smoke-test.generation" }
      expect(gen_spans).not_to be_empty

      gen_attrs = gen_spans.last.attributes
      expect(gen_attrs["gen_ai.request.model"]).not_to be_nil
      expect(gen_attrs["gen_ai.usage.input_tokens"]).to be > 0
      expect(gen_attrs["gen_ai.usage.output_tokens"]).to be > 0
      expect(gen_attrs["langfuse.observation.output"]).not_to be_nil
    end

    it "produces a tool span with observation type and I/O" do
      tool_span = find_span("smoke-test.tool.add_numbers")
      expect(tool_span).not_to be_nil

      tool_attrs = tool_span.attributes
      expect(tool_attrs["langfuse.observation.type"]).to eq("tool")
      expect(tool_attrs["langfuse.observation.input"]).not_to be_nil
      expect(tool_attrs["langfuse.observation.output"]).not_to be_nil
    end

    it "produces an agent span with agent.name" do
      agent_span = in_memory_exporter.finished_spans.find { |s| s.name.start_with?("smoke-test.agent.") }
      expect(agent_span).not_to be_nil
      expect(agent_span.attributes["agent.name"]).not_to be_nil
    end
  end

  context "with multi-agent handoff" do
    # rubocop:disable RSpec/InstanceVariable
    before do
      tracer = OpenTelemetry.tracer_provider.tracer("live-instrumentation-handoff")

      specialist = Agents::Agent.new(
        name: "Specialist",
        instructions: "You only respond with the single word READY when a conversation is transferred to you.",
        model: model,
        temperature: 0
      )

      triage = Agents::Agent.new(
        name: "Triage",
        instructions: "Immediately call the handoff tool to transfer any request to Specialist. " \
                      "Do not answer yourself.",
        model: model,
        handoff_agents: [specialist],
        temperature: 0
      )

      runner = Agents::Runner.with_agents(triage, specialist)
      Agents::Instrumentation.install(runner, tracer: tracer, trace_name: "handoff-test")

      @run_result = runner.run("Please assist me.")
      OpenTelemetry.tracer_provider.force_flush
    end

    it "completes the handoff successfully" do
      expect(@run_result.error).to be_nil
      expect(@run_result.context[:current_agent]).to eq("Specialist")
      expect(@run_result.output).to match(/ready/i)
      log_langfuse_status("handoff-test")
    end
    # rubocop:enable RSpec/InstanceVariable

    it "produces a handoff tool span under root context" do
      handoff_span = find_span("handoff-test.tool.handoff_to_specialist")
      expect(handoff_span).not_to be_nil

      attrs = handoff_span.attributes
      expect(attrs["langfuse.observation.type"]).to eq("tool")
    end

    it "produces a handoff event on the root span" do
      root = find_span("handoff-test")
      expect(root).not_to be_nil

      handoff_event = root.events&.find { |e| e.name == "handoff-test.handoff" }
      expect(handoff_event).not_to be_nil
      expect(handoff_event.attributes["handoff.from"]).to eq("Triage")
      expect(handoff_event.attributes["handoff.to"]).to eq("Specialist")
    end

    it "produces agent spans for both agents" do
      spans = in_memory_exporter.finished_spans
      triage_span = spans.find { |s| s.name == "handoff-test.agent.Triage" }
      specialist_span = spans.find { |s| s.name == "handoff-test.agent.Specialist" }

      expect(triage_span).not_to be_nil
      expect(specialist_span).not_to be_nil
      expect(triage_span.attributes["agent.name"]).to eq("Triage")
      expect(specialist_span.attributes["agent.name"]).to eq("Specialist")
    end

    it "sets trace output from the final agent response" do
      root = find_span("handoff-test")
      expect(root).not_to be_nil
      expect(root.attributes["langfuse.trace.output"]).to match(/ready/i)
    end
  end

  private

  def find_span(name)
    in_memory_exporter.finished_spans.find { |s| s.name == name }
  end

  def configure_otel(exporter)
    span_processors = [
      OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter)
    ]

    add_langfuse_processor(span_processors)

    OpenTelemetry::SDK.configure do |c|
      span_processors.each { |sp| c.add_span_processor(sp) }
    end
  end

  def add_langfuse_processor(processors)
    host = ENV["LANGFUSE_HOST"]
    pub_key = ENV["LANGFUSE_PUBLIC_KEY"]
    sec_key = ENV["LANGFUSE_SECRET_KEY"]
    return unless host && pub_key && sec_key

    require "opentelemetry-exporter-otlp"
    require "base64"

    endpoint = "#{host}/api/public/otel/v1/traces"
    auth = Base64.strict_encode64("#{pub_key}:#{sec_key}")

    $stdout.puts "\n  [langfuse] Endpoint: #{endpoint}"
    $stdout.puts "  [langfuse] Auth:     Basic #{auth[0..15]}..."

    otlp = OpenTelemetry::Exporter::OTLP::Exporter.new(
      endpoint: endpoint,
      headers: { "Authorization" => "Basic #{auth}" },
      ssl_verify_mode: OpenSSL::SSL::VERIFY_NONE
    )

    processors << OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(otlp)
  end

  def log_langfuse_status(trace_name)
    spans = in_memory_exporter.finished_spans
    $stdout.puts "\n  [langfuse] Spans captured: #{spans.size}"
    $stdout.puts "  [langfuse] Span names: #{spans.map(&:name).join(", ")}"

    root = spans.find { |s| s.name == trace_name }
    return unless root

    $stdout.puts "  [langfuse] Root trace ID: #{root.hex_trace_id}"
    $stdout.puts "  [langfuse] Check dashboard: #{ENV.fetch("LANGFUSE_HOST", nil)}"
  end
end
# rubocop:enable RSpec/DescribeClass
