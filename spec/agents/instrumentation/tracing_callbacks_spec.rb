# frozen_string_literal: true

require_relative "../../../lib/agents"
require_relative "../../../lib/agents/instrumentation"

# Stub OTel classes since the gem is optional and not loaded in tests
module OpenTelemetry
  module Trace
    # Minimal stub matching the OTel Span interface used by TracingCallbacks
    class Span
      def set_attribute(_key, _value); end
      def add_event(_name, attributes: {}); end
      def finish; end
    end

    # Minimal stub matching the OTel Tracer interface
    class Tracer
      def start_span(_name, **_opts); end
    end

    def self.context_with_span(span)
      span
    end
  end

  class Context; end
end

RSpec.describe Agents::Instrumentation::TracingCallbacks do
  let(:root_span) { instance_double(OpenTelemetry::Trace::Span) }
  let(:llm_span) { instance_double(OpenTelemetry::Trace::Span) }
  let(:tool_span) { instance_double(OpenTelemetry::Trace::Span) }
  let(:root_context) { instance_double(OpenTelemetry::Context) }
  let(:tracer) { instance_double(OpenTelemetry::Trace::Tracer) }

  let(:context_wrapper) do
    instance_double(Agents::RunContext, context: {}, callback_manager: instance_double(Agents::CallbackManager))
  end

  let(:callbacks) { described_class.new(tracer: tracer) }

  before do
    allow(root_span).to receive_messages(set_attribute: nil, add_event: nil, finish: nil)
    allow(llm_span).to receive_messages(set_attribute: nil, finish: nil)
    allow(tool_span).to receive_messages(set_attribute: nil, finish: nil)
  end

  describe "#on_run_start" do
    it "opens a root span with agents.run name" do
      allow(tracer).to receive(:start_span).and_return(root_span)

      callbacks.on_run_start("TestAgent", "Hello", context_wrapper)

      expect(tracer).to have_received(:start_span).with(
        "agents.run",
        attributes: hash_including(
          "langfuse.trace.input" => "Hello",
          "agent.name" => "TestAgent"
        )
      )
    end

    it "stores tracing state in context_wrapper" do
      allow(tracer).to receive(:start_span).and_return(root_span)

      callbacks.on_run_start("TestAgent", "Hello", context_wrapper)

      tracing = context_wrapper.context[:__otel_tracing]
      expect(tracing[:root_span]).to eq(root_span)
      expect(tracing[:current_llm_span]).to be_nil
      expect(tracing[:current_tool_span]).to be_nil
    end

    it "does NOT set gen_ai.request.model on the root span" do
      allow(tracer).to receive(:start_span).and_return(root_span)

      callbacks.on_run_start("TestAgent", "Hello", context_wrapper)

      expect(tracer).to have_received(:start_span).with(
        "agents.run",
        attributes: hash_not_including("gen_ai.request.model")
      )
    end

    context "with attribute_provider" do
      it "merges dynamic attributes into root span" do
        provider = ->(_ctx) { { "langfuse.user.id" => "user_42", "langfuse.session.id" => "sess_1" } }
        cb = described_class.new(tracer: tracer, attribute_provider: provider)

        allow(tracer).to receive(:start_span).and_return(root_span)

        cb.on_run_start("TestAgent", "Hello", context_wrapper)

        expect(tracer).to have_received(:start_span).with(
          "agents.run",
          attributes: hash_including(
            "langfuse.user.id" => "user_42",
            "langfuse.session.id" => "sess_1"
          )
        )
      end
    end

    context "with static span_attributes" do
      it "includes static attributes on root span" do
        cb = described_class.new(tracer: tracer, span_attributes: { "langfuse.trace.tags" => '["v2"]' })

        allow(tracer).to receive(:start_span).and_return(root_span)

        cb.on_run_start("TestAgent", "Hello", context_wrapper)

        expect(tracer).to have_received(:start_span).with(
          "agents.run",
          attributes: hash_including("langfuse.trace.tags" => '["v2"]')
        )
      end
    end
  end

  describe "#on_agent_thinking" do
    before do
      allow(tracer).to receive(:start_span).and_return(root_span)
      callbacks.on_run_start("TestAgent", "Hello", context_wrapper)
    end

    it "opens a child LLM span" do
      allow(tracer).to receive(:start_span).and_return(llm_span)

      callbacks.on_agent_thinking("TestAgent", "Hello", context_wrapper)

      expect(tracer).to have_received(:start_span).with(
        "agents.llm_call",
        with_parent: context_wrapper.context[:__otel_tracing][:root_context],
        attributes: hash_including("langfuse.observation.input" => "Hello")
      )
    end

    it "stores the LLM span in tracing state" do
      allow(tracer).to receive(:start_span).and_return(llm_span)

      callbacks.on_agent_thinking("TestAgent", "Hello", context_wrapper)

      expect(context_wrapper.context[:__otel_tracing][:current_llm_span]).to eq(llm_span)
    end

    context "without prior run_start" do
      it "does nothing when no tracing state exists" do
        fresh_context = instance_double(Agents::RunContext, context: {})
        expect { callbacks.on_agent_thinking("TestAgent", "Hello", fresh_context) }.not_to raise_error
      end
    end
  end

  describe "#on_llm_call_complete" do
    let(:response) do
      instance_double(RubyLLM::Message,
                      input_tokens: 150,
                      output_tokens: 50,
                      content: "I can help with that")
    end

    before do
      allow(tracer).to receive(:start_span).and_return(root_span, llm_span)
      callbacks.on_run_start("TestAgent", "Hello", context_wrapper)
      callbacks.on_agent_thinking("TestAgent", "Hello", context_wrapper)
    end

    it "sets gen_ai.request.model on the LLM span" do
      callbacks.on_llm_call_complete("TestAgent", "gpt-4o", response, context_wrapper)

      expect(llm_span).to have_received(:set_attribute).with("gen_ai.request.model", "gpt-4o")
    end

    it "sets input and output token counts" do
      callbacks.on_llm_call_complete("TestAgent", "gpt-4o", response, context_wrapper)

      expect(llm_span).to have_received(:set_attribute).with("gen_ai.usage.input_tokens", 150)
      expect(llm_span).to have_received(:set_attribute).with("gen_ai.usage.output_tokens", 50)
    end

    it "sets observation output" do
      callbacks.on_llm_call_complete("TestAgent", "gpt-4o", response, context_wrapper)

      expect(llm_span).to have_received(:set_attribute).with("langfuse.observation.output", "I can help with that")
    end

    it "finishes the LLM span" do
      callbacks.on_llm_call_complete("TestAgent", "gpt-4o", response, context_wrapper)

      expect(llm_span).to have_received(:finish)
    end

    it "clears current_llm_span from tracing state" do
      callbacks.on_llm_call_complete("TestAgent", "gpt-4o", response, context_wrapper)

      expect(context_wrapper.context[:__otel_tracing][:current_llm_span]).to be_nil
    end

    context "when response lacks token methods" do
      let(:halt_response) { instance_double(RubyLLM::Tool::Halt, content: "halted") }

      before do
        allow(halt_response).to receive(:respond_to?).and_return(false)
        allow(halt_response).to receive(:respond_to?).with(:content).and_return(true)
      end

      it "skips token attributes gracefully" do
        callbacks.on_llm_call_complete("TestAgent", "gpt-4o", halt_response, context_wrapper)

        expect(llm_span).not_to have_received(:set_attribute).with("gen_ai.usage.input_tokens", anything)
        expect(llm_span).not_to have_received(:set_attribute).with("gen_ai.usage.output_tokens", anything)
      end
    end
  end

  describe "#on_tool_start" do
    before do
      allow(tracer).to receive(:start_span).and_return(root_span)
      callbacks.on_run_start("TestAgent", "Hello", context_wrapper)
    end

    it "opens a child tool span with correct name" do
      allow(tracer).to receive(:start_span).and_return(tool_span)

      callbacks.on_tool_start("lookup_user", { user_id: 123 }, context_wrapper)

      expect(tracer).to have_received(:start_span).with(
        "agents.tool.lookup_user",
        with_parent: context_wrapper.context[:__otel_tracing][:root_context],
        attributes: hash_including("langfuse.observation.type" => "tool")
      )
    end

    it "does NOT set gen_ai.request.model on tool span" do
      allow(tracer).to receive(:start_span).and_return(tool_span)

      callbacks.on_tool_start("lookup_user", { user_id: 123 }, context_wrapper)

      expect(tracer).to have_received(:start_span).with(
        "agents.tool.lookup_user",
        with_parent: anything,
        attributes: hash_not_including("gen_ai.request.model")
      )
    end

    it "stores the tool span in tracing state" do
      allow(tracer).to receive(:start_span).and_return(tool_span)

      callbacks.on_tool_start("lookup_user", { user_id: 123 }, context_wrapper)

      expect(context_wrapper.context[:__otel_tracing][:current_tool_span]).to eq(tool_span)
    end
  end

  describe "#on_tool_complete" do
    before do
      allow(tracer).to receive(:start_span).and_return(root_span, tool_span)
      callbacks.on_run_start("TestAgent", "Hello", context_wrapper)
      callbacks.on_tool_start("lookup_user", { user_id: 123 }, context_wrapper)
    end

    it "sets output on the tool span" do
      callbacks.on_tool_complete("lookup_user", "User found: John", context_wrapper)

      expect(tool_span).to have_received(:set_attribute).with("langfuse.observation.output", "User found: John")
    end

    it "finishes the tool span" do
      callbacks.on_tool_complete("lookup_user", "User found: John", context_wrapper)

      expect(tool_span).to have_received(:finish)
    end

    it "clears current_tool_span from tracing state" do
      callbacks.on_tool_complete("lookup_user", "User found: John", context_wrapper)

      expect(context_wrapper.context[:__otel_tracing][:current_tool_span]).to be_nil
    end
  end

  describe "#on_agent_handoff" do
    before do
      allow(tracer).to receive(:start_span).and_return(root_span)
      callbacks.on_run_start("Triage", "Hello", context_wrapper)
    end

    it "adds an event to the root span (not a child span)" do
      callbacks.on_agent_handoff("Triage", "Billing", "handoff", context_wrapper)

      expect(root_span).to have_received(:add_event).with(
        "agents.handoff",
        attributes: {
          "handoff.from" => "Triage",
          "handoff.to" => "Billing",
          "handoff.reason" => "handoff"
        }
      )
    end
  end

  describe "#on_run_complete" do
    let(:run_result) { instance_double(Agents::RunResult, output: "Final answer") }

    before do
      allow(tracer).to receive(:start_span).and_return(root_span)
      callbacks.on_run_start("TestAgent", "Hello", context_wrapper)
    end

    it "sets trace output on the root span" do
      callbacks.on_run_complete("TestAgent", run_result, context_wrapper)

      expect(root_span).to have_received(:set_attribute).with("langfuse.trace.output", "Final answer")
    end

    it "finishes the root span" do
      callbacks.on_run_complete("TestAgent", run_result, context_wrapper)

      expect(root_span).to have_received(:finish)
    end

    it "cleans up tracing state from context" do
      callbacks.on_run_complete("TestAgent", run_result, context_wrapper)

      expect(context_wrapper.context[:__otel_tracing]).to be_nil
    end
  end

  describe "#on_run_complete with dangling spans" do
    let(:run_result) { instance_double(Agents::RunResult, output: "error result") }

    before do
      allow(tracer).to receive(:start_span).and_return(root_span, llm_span)
      callbacks.on_run_start("TestAgent", "Hello", context_wrapper)
      # Simulate: on_agent_thinking opens LLM span, then chat.ask raises
      # so on_llm_call_complete is never called
      callbacks.on_agent_thinking("TestAgent", "Hello", context_wrapper)
    end

    it "closes dangling LLM span before closing root span" do
      callbacks.on_run_complete("TestAgent", run_result, context_wrapper)

      expect(llm_span).to have_received(:finish)
      expect(root_span).to have_received(:finish)
    end

    it "clears dangling LLM span from tracing state" do
      # Before on_run_complete, the LLM span should still be open
      expect(context_wrapper.context[:__otel_tracing][:current_llm_span]).to eq(llm_span)

      callbacks.on_run_complete("TestAgent", run_result, context_wrapper)

      expect(context_wrapper.context[:__otel_tracing]).to be_nil
    end

    context "with dangling tool span" do
      before do
        # Close the LLM span normally, then open a tool span that never closes
        callbacks.on_llm_call_complete("TestAgent", "gpt-4o",
                                       instance_double(RubyLLM::Message, input_tokens: 10,
                                                                         output_tokens: 5,
                                                                         content: "ok"),
                                       context_wrapper)
        allow(tracer).to receive(:start_span).and_return(tool_span)
        callbacks.on_tool_start("failing_tool", { key: "val" }, context_wrapper)
      end

      it "closes dangling tool span before closing root span" do
        callbacks.on_run_complete("TestAgent", run_result, context_wrapper)

        expect(tool_span).to have_received(:finish)
        expect(root_span).to have_received(:finish)
      end
    end
  end

  describe "tracing state isolation" do
    it "stores tracing state per context_wrapper" do
      context1 = instance_double(Agents::RunContext, context: {})
      context2 = instance_double(Agents::RunContext, context: {})
      span1 = instance_double(OpenTelemetry::Trace::Span)
      span2 = instance_double(OpenTelemetry::Trace::Span)

      allow(span1).to receive_messages(set_attribute: nil, finish: nil)
      allow(span2).to receive_messages(set_attribute: nil, finish: nil)

      allow(tracer).to receive(:start_span).and_return(span1, span2)

      callbacks.on_run_start("Agent1", "msg1", context1)
      callbacks.on_run_start("Agent2", "msg2", context2)

      expect(context1.context[:__otel_tracing][:root_span]).to eq(span1)
      expect(context2.context[:__otel_tracing][:root_span]).to eq(span2)
    end
  end

  # Custom matcher for hash_not_including
  RSpec::Matchers.define :hash_not_including do |*keys|
    match do |actual|
      actual.is_a?(Hash) && keys.none? { |key| actual.key?(key) }
    end
  end
end
