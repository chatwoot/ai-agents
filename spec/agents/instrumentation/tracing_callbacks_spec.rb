# frozen_string_literal: true

require_relative "../../../lib/agents"
require_relative "../../../lib/agents/instrumentation"

begin
  require "opentelemetry-api"
rescue LoadError
  # Minimal OTel stubs for environments where opentelemetry-api isn't installed.
  module OpenTelemetry
    module Trace
      class Status
        attr_reader :code, :description

        def initialize(code:, description:)
          @code = code
          @description = description
        end

        def self.error(description)
          new(code: 2, description: description)
        end
      end

      # Minimal stub matching the OTel Span interface used by TracingCallbacks
      class Span
        def set_attribute(_key, _value); end
        def add_event(_name, attributes: {}); end
        def record_exception(_exception); end
        def status=(_status); end
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
end

RSpec.describe Agents::Instrumentation::TracingCallbacks do
  let(:root_span) { instance_double(OpenTelemetry::Trace::Span) }
  let(:llm_span) { instance_double(OpenTelemetry::Trace::Span) }
  let(:tool_span) { instance_double(OpenTelemetry::Trace::Span) }
  let(:agent_span) { instance_double(OpenTelemetry::Trace::Span) }
  let(:root_context) { instance_double(OpenTelemetry::Context) }
  let(:agent_context) { instance_double(OpenTelemetry::Context) }
  let(:tracer) { instance_double(OpenTelemetry::Trace::Tracer) }

  let(:context_wrapper) do
    instance_double(Agents::RunContext, context: {}, callback_manager: instance_double(Agents::CallbackManager))
  end

  let(:callbacks) { described_class.new(tracer: tracer) }

  before do
    allow(root_span).to receive_messages(set_attribute: nil, add_event: nil, record_exception: nil, finish: nil)
    allow(root_span).to receive(:status=)
    allow(llm_span).to receive_messages(set_attribute: nil, finish: nil)
    allow(tool_span).to receive_messages(set_attribute: nil, finish: nil)
    allow(agent_span).to receive_messages(set_attribute: nil, finish: nil)
  end

  def build_context(context = {})
    instance_double(Agents::RunContext, context: context, callback_manager: instance_double(Agents::CallbackManager))
  end

  def langfuse_metadata_provider
    lambda do |_ctx|
      {
        "langfuse.user.id" => "user_42",
        "langfuse.trace.metadata.assistant_id" => "123",
        "langfuse.release" => "2026.06.29",
        "langfuse.version" => "sha-abc123",
        "langfuse.observation.type" => "should_not_propagate"
      }
    end
  end

  def callbacks_with_langfuse_metadata(trace_tags: '["captain_v2"]')
    described_class.new(
      tracer: tracer,
      span_attributes: { "langfuse.trace.tags" => trace_tags },
      attribute_provider: langfuse_metadata_provider
    )
  end

  def start_langfuse_metadata_run(callbacks, context)
    allow(tracer).to receive(:start_span).and_return(root_span, agent_span)
    callbacks.on_run_start("TestAgent", "Hello", context)
    callbacks.on_agent_thinking("TestAgent", "What is your refund policy?", context)
    allow(tracer).to receive(:start_span).and_return(llm_span)
  end

  def trace_generation(callbacks, chat, _agent_name, model, context, temperature = nil)
    messages = chat.messages
    payload = { chat: chat, model: model, temperature: temperature, input_messages: messages[0...-1] }
    callbacks.on_native_event(:start, "chat.ruby_llm", payload, context)
    payload[:response] = messages.last
    callbacks.on_native_event(:finish, "chat.ruby_llm", payload, context)
  end

  def configure_tool_flow_chat(chat, system_message, user_message, assistant_message)
    tool_call_msg = instance_double(
      RubyLLM::Message,
      role: :assistant,
      content: nil,
      tokens: RubyLLM::Tokens.new(input: 100, output: 20),
      tool_call?: true,
      tool_calls: {
        "c1" => instance_double(RubyLLM::ToolCall, name: "faq_lookup", arguments: { query: "refund" })
      }
    )
    tool_result_msg = instance_double(RubyLLM::Message, role: :tool, content: "Refund policy: 30 days")
    messages_call = 0

    allow(chat).to receive(:messages) do
      messages_call += 1
      next [system_message, user_message, tool_call_msg] if messages_call == 1

      [system_message, user_message, tool_call_msg, tool_result_msg, assistant_message]
    end
  end

  def capture_generation_span_attributes
    generation_attrs = []
    allow(tracer).to receive(:start_span) do |name, **opts|
      generation_attrs << opts[:attributes] if name == "agents.run.generation"
      llm_span
    end
    generation_attrs
  end

  describe "#on_run_start" do
    it "opens a root span with agents.run name" do
      allow(tracer).to receive(:start_span).and_return(root_span)

      callbacks.on_run_start("TestAgent", "Hello", context_wrapper)

      expect(tracer).to have_received(:start_span).with(
        "agents.run",
        attributes: hash_including(
          "langfuse.trace.input" => "Hello",
          "langfuse.observation.input" => "Hello",
          "agent.name" => "TestAgent"
        )
      )
    end

    it "stores tracing state in context_wrapper" do
      allow(tracer).to receive(:start_span).and_return(root_span)

      callbacks.on_run_start("TestAgent", "Hello", context_wrapper)

      tracing = context_wrapper.context[:__otel_tracing]
      expect(tracing[:root_span]).to eq(root_span)
      expect(tracing[:child_langfuse_attributes]).to eq({})
      expect(tracing[:current_tool_span]).to be_nil
      expect(tracing[:current_agent_name]).to be_nil
      expect(tracing[:current_agent_span]).to be_nil
      expect(tracing[:current_agent_context]).to be_nil
    end

    it "prepares Langfuse trace metadata for child observation spans" do
      cb = callbacks_with_langfuse_metadata(trace_tags: ["captain_v2"])
      ctx = build_context(session_id: "acct_1_conv_2")
      allow(tracer).to receive(:start_span).and_return(root_span)

      cb.on_run_start("TestAgent", "Hello", ctx)

      child_attrs = ctx.context[:__otel_tracing][:child_langfuse_attributes]
      expect(child_attrs).to include(
        "langfuse.user.id" => "user_42",
        "langfuse.session.id" => "acct_1_conv_2",
        "langfuse.trace.tags" => ["captain_v2"],
        "langfuse.trace.metadata.assistant_id" => "123",
        "langfuse.release" => "2026.06.29",
        "langfuse.version" => "sha-abc123",
        "langfuse.observation.metadata.user_id" => "user_42",
        "langfuse.observation.metadata.session_id" => "acct_1_conv_2",
        "langfuse.observation.metadata.trace_tags" => ["captain_v2"].to_json,
        "langfuse.observation.metadata.assistant_id" => "123"
      )
      expect(child_attrs).not_to include("langfuse.trace.input")
      expect(child_attrs).not_to include("langfuse.observation.input")
      expect(child_attrs).not_to include("langfuse.observation.type")
    end

    it "does NOT set gen_ai.request.model on the root span" do
      allow(tracer).to receive(:start_span).and_return(root_span)

      callbacks.on_run_start("TestAgent", "Hello", context_wrapper)

      expect(tracer).to have_received(:start_span).with(
        "agents.run",
        attributes: hash_not_including("gen_ai.request.model")
      )
    end

    context "with custom trace_name" do
      let(:custom_callbacks) { described_class.new(tracer: tracer, trace_name: "llm.captain_v2") }

      before do
        allow(tracer).to receive(:start_span).and_return(root_span)
        custom_callbacks.on_run_start("TestAgent", "Hello", context_wrapper)
      end

      it "uses the custom name for the root span" do
        expect(tracer).to have_received(:start_span).with(
          "llm.captain_v2",
          attributes: hash_including("agent.name" => "TestAgent")
        )
      end

      it "derives LLM span name from trace_name" do
        chat = instance_double(RubyLLM::Chat)
        user_msg = instance_double(RubyLLM::Message, role: :user, content: "Hi")
        assistant_msg = instance_double(RubyLLM::Message,
                                        role: :assistant, tokens: RubyLLM::Tokens.new(input: 10, output: 5),
                                        content: "Hello", tool_call?: false, tool_calls: {})
        allow(chat).to receive(:messages).and_return([user_msg, assistant_msg])
        allow(tracer).to receive(:start_span).and_return(llm_span)

        trace_generation(custom_callbacks, chat, "TestAgent", "gpt-4o", context_wrapper)

        expect(tracer).to have_received(:start_span).with(
          "llm.captain_v2.generation",
          with_parent: anything,
          attributes: anything
        )
      end

      it "derives tool span name from trace_name" do
        allow(tracer).to receive(:start_span).and_return(tool_span)

        custom_callbacks.on_tool_start("faq_lookup", { query: "refund" }, context_wrapper)

        expect(tracer).to have_received(:start_span).with(
          "llm.captain_v2.tool.faq_lookup",
          with_parent: anything,
          attributes: anything
        )
      end

      it "derives handoff event name from trace_name" do
        custom_callbacks.on_agent_handoff("Triage", "Billing", "handoff", context_wrapper)

        expect(root_span).to have_received(:add_event).with(
          "llm.captain_v2.handoff",
          attributes: hash_including("handoff.from" => "Triage", "handoff.to" => "Billing")
        )
      end

      it "derives agent span name from trace_name" do
        allow(tracer).to receive(:start_span).and_return(agent_span)

        custom_callbacks.on_agent_thinking("Triage", "Hello", context_wrapper)

        expect(tracer).to have_received(:start_span).with(
          "llm.captain_v2.agent.Triage",
          with_parent: anything,
          attributes: hash_including("agent.name" => "Triage", "langfuse.observation.input" => "Hello")
        )
      end
    end

    context "with session_id in context" do
      it "sets langfuse.session.id on root span from context" do
        ctx = instance_double(Agents::RunContext, context: { session_id: "1_1" },
                                                  callback_manager: instance_double(Agents::CallbackManager))
        allow(tracer).to receive(:start_span).and_return(root_span)

        callbacks.on_run_start("TestAgent", "Hello", ctx)

        expect(tracer).to have_received(:start_span).with(
          "agents.run",
          attributes: hash_including("langfuse.session.id" => "1_1")
        )
      end

      it "does not set langfuse.session.id when context has no session_id" do
        allow(tracer).to receive(:start_span).and_return(root_span)

        callbacks.on_run_start("TestAgent", "Hello", context_wrapper)

        expect(tracer).to have_received(:start_span).with(
          "agents.run",
          attributes: hash_not_including("langfuse.session.id")
        )
      end
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

    it "stores input in tracing state for the next LLM span" do
      allow(tracer).to receive(:start_span).and_return(agent_span)

      callbacks.on_agent_thinking("TestAgent", "What is your refund policy?", context_wrapper)

      expect(context_wrapper.context[:__otel_tracing][:pending_llm_input]).to eq("What is your refund policy?")
    end

    it "opens an agent span as child of root on first call" do
      allow(tracer).to receive(:start_span).and_return(agent_span)

      callbacks.on_agent_thinking("TestAgent", "Hello", context_wrapper)

      expect(tracer).to have_received(:start_span).with(
        "agents.run.agent.TestAgent",
        with_parent: context_wrapper.context[:__otel_tracing][:root_context],
        attributes: hash_including("agent.name" => "TestAgent")
      )
    end

    it "sets observation input on the agent span from pending input" do
      allow(tracer).to receive(:start_span).and_return(agent_span)

      callbacks.on_agent_thinking("TestAgent", "What is your refund policy?", context_wrapper)

      expect(tracer).to have_received(:start_span).with(
        "agents.run.agent.TestAgent",
        with_parent: anything,
        attributes: hash_including("langfuse.observation.input" => "What is your refund policy?")
      )
    end

    it "stores agent span state in tracing" do
      allow(tracer).to receive(:start_span).and_return(agent_span)

      callbacks.on_agent_thinking("TestAgent", "Hello", context_wrapper)

      tracing = context_wrapper.context[:__otel_tracing]
      expect(tracing[:current_agent_name]).to eq("TestAgent")
      expect(tracing[:current_agent_span]).to eq(agent_span)
      expect(tracing[:current_agent_context]).not_to be_nil
    end

    it "does not open a new agent span for the same agent name" do
      allow(tracer).to receive(:start_span).and_return(agent_span)

      callbacks.on_agent_thinking("TestAgent", "Hello", context_wrapper)
      callbacks.on_agent_thinking("TestAgent", "Follow up", context_wrapper)

      # root_span + 1 agent span = 2 total start_span calls
      expect(tracer).to have_received(:start_span).twice
    end

    it "opens a new agent span when agent name changes and closes previous" do
      agent_span2 = instance_double(OpenTelemetry::Trace::Span)
      allow(agent_span2).to receive_messages(set_attribute: nil, finish: nil)
      allow(tracer).to receive(:start_span).and_return(agent_span, agent_span2)

      callbacks.on_agent_thinking("Triage", "Hello", context_wrapper)
      callbacks.on_agent_thinking("Billing", "Billing question", context_wrapper)

      expect(agent_span).to have_received(:finish)
      expect(tracer).to have_received(:start_span).with(
        "agents.run.agent.Billing",
        with_parent: anything,
        attributes: hash_including("agent.name" => "Billing")
      )
      expect(context_wrapper.context[:__otel_tracing][:current_agent_name]).to eq("Billing")
      expect(context_wrapper.context[:__otel_tracing][:current_agent_span]).to eq(agent_span2)
    end

    context "without prior run_start" do
      it "does nothing when no tracing state exists" do
        fresh_context = instance_double(Agents::RunContext, context: {})
        expect { callbacks.on_agent_thinking("TestAgent", "Hello", fresh_context) }.not_to raise_error
      end
    end
  end

  describe "#on_agent_complete" do
    before do
      allow(tracer).to receive(:start_span).and_return(root_span, agent_span)
      callbacks.on_run_start("TestAgent", "Hello", context_wrapper)
      callbacks.on_agent_thinking("TestAgent", "Hello", context_wrapper)
    end

    it "closes current agent span" do
      callbacks.on_agent_complete("TestAgent", nil, nil, context_wrapper)

      expect(agent_span).to have_received(:finish)
    end

    it "clears agent state from tracing" do
      callbacks.on_agent_complete("TestAgent", nil, nil, context_wrapper)

      tracing = context_wrapper.context[:__otel_tracing]
      expect(tracing[:current_agent_name]).to be_nil
      expect(tracing[:current_agent_span]).to be_nil
      expect(tracing[:current_agent_context]).to be_nil
    end

    it "backfills observation output on agent span from last LLM response" do
      chat = instance_double(RubyLLM::Chat)
      assistant_msg = instance_double(RubyLLM::Message,
                                      role: :assistant, tokens: RubyLLM::Tokens.new(input: 10, output: 5),
                                      content: "Here is your answer", tool_call?: false, tool_calls: {})
      allow(chat).to receive(:messages).and_return([
                                                     instance_double(RubyLLM::Message, role: :user, content: "Hi"),
                                                     assistant_msg
                                                   ])
      allow(tracer).to receive(:start_span).and_return(llm_span)

      trace_generation(callbacks, chat, "TestAgent", "gpt-4o", context_wrapper)
      callbacks.on_agent_complete("TestAgent", nil, nil, context_wrapper)

      expect(agent_span).to have_received(:set_attribute).with(
        "langfuse.observation.output", "Here is your answer"
      )
    end

    it "does not set observation output on agent span when no LLM response occurred" do
      callbacks.on_agent_complete("TestAgent", nil, nil, context_wrapper)

      expect(agent_span).not_to have_received(:set_attribute).with("langfuse.observation.output", anything)
    end

    context "without tracing state" do
      it "does nothing when no tracing state exists" do
        fresh_context = instance_double(Agents::RunContext, context: {})
        expect { callbacks.on_agent_complete("TestAgent", nil, nil, fresh_context) }.not_to raise_error
      end
    end
  end

  describe "#on_native_event" do
    let(:chat) { instance_double(RubyLLM::Chat) }
    let(:system_message) { instance_double(RubyLLM::Message, role: :system, content: "You are a helpful assistant") }
    let(:user_message) { instance_double(RubyLLM::Message, role: :user, content: "What is your refund policy?") }

    let(:assistant_message) do
      instance_double(RubyLLM::Message,
                      role: :assistant,
                      tokens: RubyLLM::Tokens.new(input: 150, output: 50),
                      content: "I can help with that",
                      tool_call?: false,
                      tool_calls: {})
    end

    before do
      allow(tracer).to receive(:start_span).and_return(root_span, agent_span)
      callbacks.on_run_start("TestAgent", "Hello", context_wrapper)
      callbacks.on_agent_thinking("TestAgent", "What is your refund policy?", context_wrapper)
      # Chat messages: everything up to and including the current response
      allow(chat).to receive(:messages).and_return([system_message, user_message, assistant_message])
    end

    it "keeps the generation span open until the provider operation finishes" do
      allow(tracer).to receive(:start_span).and_return(llm_span)
      payload = { chat: chat, model: "gpt-4o", input_messages: [user_message] }

      callbacks.on_native_event(:start, "chat.ruby_llm", payload, context_wrapper)
      expect(llm_span).not_to have_received(:finish)
      payload[:response] = assistant_message
      callbacks.on_native_event(:finish, "chat.ruby_llm", payload, context_wrapper)

      expect(llm_span).to have_received(:finish).once
    end

    it "records provider errors and closes the generation" do
      allow(tracer).to receive(:start_span).and_return(llm_span)
      allow(llm_span).to receive(:record_exception)
      allow(llm_span).to receive(:status=)
      payload = { model: "gpt-4o", input_messages: [user_message] }
      error = StandardError.new("Request failed")

      callbacks.on_native_event(:start, "chat.ruby_llm", payload, context_wrapper)
      payload[:error] = error
      callbacks.on_native_event(:finish, "chat.ruby_llm", payload, context_wrapper)

      expect(llm_span).to have_received(:record_exception).with(error)
      expect(llm_span).to have_received(:finish).once
    end

    it "includes native attachment sources in generation input" do
      message = RubyLLM::Message.new(role: :user, content: nil, attachments: ["https://example.com/image.png"])
      allow(tracer).to receive(:start_span).and_return(llm_span)

      callbacks.on_native_event(:start, "chat.ruby_llm", { input_messages: [message] }, context_wrapper)

      expect(tracer).to have_received(:start_span).with(
        "agents.run.generation", with_parent: anything,
                                 attributes: hash_including("langfuse.observation.input" =>
          [{ role: "user", content: "Attachments: https://example.com/image.png" }].to_json)
      )
    end

    it "parents LLM spans under agent context" do
      allow(tracer).to receive(:start_span).and_return(llm_span)

      trace_generation(callbacks, chat, "TestAgent", "gpt-4o", context_wrapper)

      agent_ctx = context_wrapper.context[:__otel_tracing][:current_agent_context]
      expect(tracer).to have_received(:start_span).with(
        "agents.run.generation",
        with_parent: agent_ctx,
        attributes: anything
      )
    end

    it "falls back to root context when no agent span" do
      # Clear agent span state to simulate no agent span
      tracing = context_wrapper.context[:__otel_tracing]
      tracing[:current_agent_name] = nil
      tracing[:current_agent_span] = nil
      tracing[:current_agent_context] = nil

      allow(tracer).to receive(:start_span).and_return(llm_span)

      trace_generation(callbacks, chat, "TestAgent", "gpt-4o", context_wrapper)

      expect(tracer).to have_received(:start_span).with(
        "agents.run.generation",
        with_parent: tracing[:root_context],
        attributes: anything
      )
    end

    it "sets observation input as JSON array of chat messages excluding the response" do
      allow(tracer).to receive(:start_span).and_return(llm_span)

      trace_generation(callbacks, chat, "TestAgent", "gpt-4o", context_wrapper)

      expected_input = [
        { role: "system", content: "You are a helpful assistant" },
        { role: "user", content: "What is your refund policy?" }
      ].to_json

      expect(tracer).to have_received(:start_span).with(
        "agents.run.generation",
        with_parent: anything,
        attributes: hash_including("langfuse.observation.input" => expected_input)
      )
      expect(llm_span).to have_received(:set_attribute).with("gen_ai.request.model", "gpt-4o")
      expect(llm_span).to have_received(:finish)
    end

    it "sets request temperature on generation spans when provided" do
      allow(tracer).to receive(:start_span).and_return(llm_span)

      trace_generation(callbacks, chat, "TestAgent", "gpt-4o", context_wrapper, 0.2)

      expect(llm_span).to have_received(:set_attribute).with("gen_ai.request.temperature", 0.2)
    end

    it "propagates root Langfuse metadata to LLM generation spans" do
      cb = callbacks_with_langfuse_metadata
      fresh_context = build_context(session_id: "acct_1_conv_2")
      start_langfuse_metadata_run(cb, fresh_context)

      trace_generation(cb, chat, "TestAgent", "gpt-4o", fresh_context)

      expect(tracer).to have_received(:start_span).with(
        "agents.run.generation",
        with_parent: anything,
        attributes: hash_including(
          "langfuse.user.id" => "user_42",
          "langfuse.session.id" => "acct_1_conv_2",
          "langfuse.trace.tags" => '["captain_v2"]',
          "langfuse.trace.metadata.assistant_id" => "123",
          "langfuse.release" => "2026.06.29",
          "langfuse.version" => "sha-abc123",
          "langfuse.observation.metadata.user_id" => "user_42",
          "langfuse.observation.metadata.session_id" => "acct_1_conv_2",
          "langfuse.observation.metadata.trace_tags" => '["captain_v2"]',
          "langfuse.observation.metadata.assistant_id" => "123"
        )
      )
    end

    it "adds caller-provided generation attributes" do
      provider = Class.new do
        def call(_ctx)
          {}
        end

        def generation_attributes(_ctx, _chat, message)
          { "app.generation.has_tool_calls" => message.tool_calls&.any? }
        end
      end
      cb = described_class.new(tracer: tracer, attribute_provider: provider.new)
      fresh_context = build_context
      allow(tracer).to receive(:start_span).and_return(root_span, agent_span)
      cb.on_run_start("TestAgent", "Hello", fresh_context)
      cb.on_agent_thinking("TestAgent", "What is your refund policy?", fresh_context)
      allow(tracer).to receive(:start_span).and_return(llm_span)

      trace_generation(cb, chat, "TestAgent", "gpt-4o", fresh_context)

      expect(llm_span).to have_received(:set_attribute).with("app.generation.has_tool_calls", false)
    end

    it "includes tool results in input when tools ran between LLM calls" do
      configure_tool_flow_chat(chat, system_message, user_message, assistant_message)
      generation_attrs = capture_generation_span_attributes

      2.times { trace_generation(callbacks, chat, "TestAgent", "gpt-4o", context_wrapper) }

      # First LLM span input: just system + user (before tool results)
      first_input = [
        { role: "system", content: "You are a helpful assistant" },
        { role: "user", content: "What is your refund policy?" }
      ].to_json

      # Second LLM span input: includes tool call (with tool call details) + tool result
      second_input = [
        { role: "system", content: "You are a helpful assistant" },
        { role: "user", content: "What is your refund policy?" },
        { role: "assistant", content: "Tool calls: faq_lookup(#{{ query: "refund" }.to_json})" },
        { role: "tool", content: "Refund policy: 30 days" }
      ].to_json

      expect(generation_attrs.map { |attrs| attrs["langfuse.observation.input"] }).to eq([first_input, second_input])
    end

    it "sets token usage attributes on the LLM span" do
      allow(tracer).to receive(:start_span).and_return(llm_span)

      trace_generation(callbacks, chat, "TestAgent", "gpt-4o", context_wrapper)

      expect(llm_span).to have_received(:set_attribute).with("gen_ai.usage.input_tokens", 150)
      expect(llm_span).to have_received(:set_attribute).with("gen_ai.usage.output_tokens", 50)
    end

    it "sets observation output on the LLM span" do
      allow(tracer).to receive(:start_span).and_return(llm_span)

      trace_generation(callbacks, chat, "TestAgent", "gpt-4o", context_wrapper)

      expect(llm_span).to have_received(:set_attribute).with("langfuse.observation.output", "I can help with that")
    end

    context "with tool-call-only assistant message (no text content)" do
      let(:tool_call) do
        instance_double(RubyLLM::ToolCall, name: "faq_lookup", arguments: { query: "refund" })
      end
      let(:tool_call_message) do
        instance_double(RubyLLM::Message,
                        role: :assistant,
                        tokens: RubyLLM::Tokens.new(input: 100, output: 20),
                        content: nil,
                        tool_call?: true,
                        tool_calls: { "call_123" => tool_call })
      end

      before do
        allow(chat).to receive(:messages).and_return([system_message, user_message, tool_call_message])
      end

      it "formats tool calls as output when content is nil" do
        allow(tracer).to receive(:start_span).and_return(llm_span)

        trace_generation(callbacks, chat, "TestAgent", "gpt-4o", context_wrapper)

        expect(llm_span).to have_received(:set_attribute).with(
          "langfuse.observation.output",
          "Tool calls: faq_lookup(#{tool_call.arguments.to_json})"
        )
      end
    end

    context "with empty content and no tool calls" do
      let(:empty_message) do
        instance_double(RubyLLM::Message,
                        role: :assistant,
                        tokens: RubyLLM::Tokens.new(input: 100, output: 0),
                        content: nil,
                        tool_call?: false,
                        tool_calls: {})
      end

      before do
        allow(chat).to receive(:messages).and_return([system_message, user_message, empty_message])
      end

      it "does not set observation output when output text is empty" do
        allow(tracer).to receive(:start_span).and_return(llm_span)

        trace_generation(callbacks, chat, "TestAgent", "gpt-4o", context_wrapper)

        expect(llm_span).not_to have_received(:set_attribute).with("langfuse.observation.output", anything)
      end
    end

    it "ignores non-generation native events" do
      callbacks.on_native_event(:start, "tool_call.ruby_llm", {}, context_wrapper)

      expect(tracer).to have_received(:start_span).twice
    end

    context "without model" do
      it "skips setting model attribute when model is nil" do
        allow(tracer).to receive(:start_span).and_return(llm_span)

        trace_generation(callbacks, chat, "TestAgent", nil, context_wrapper)

        expect(llm_span).not_to have_received(:set_attribute).with("gen_ai.request.model", anything)
      end

      it "skips setting temperature attribute when temperature is nil" do
        allow(tracer).to receive(:start_span).and_return(llm_span)

        trace_generation(callbacks, chat, "TestAgent", "gpt-4o", context_wrapper)

        expect(llm_span).not_to have_received(:set_attribute).with("gen_ai.request.temperature", anything)
      end
    end

    context "without prior run_start" do
      it "does not create a generation when no tracing state exists" do
        fresh_context = instance_double(Agents::RunContext, context: {})

        trace_generation(callbacks, chat, "TestAgent", "gpt-4o", fresh_context)

        expect(tracer).to have_received(:start_span).twice
      end
    end

    context "with Hash/Array content in messages" do
      it "serializes Hash content as JSON in chat message input" do
        hash_msg = instance_double(RubyLLM::Message, role: :assistant, content: { key: "value" },
                                                     tool_call?: false, tool_calls: {},
                                                     tokens: RubyLLM::Tokens.new(input: 10, output: 5))
        allow(chat).to receive(:messages).and_return([user_message, hash_msg, assistant_message])
        allow(tracer).to receive(:start_span).and_return(llm_span)

        trace_generation(callbacks, chat, "TestAgent", "gpt-4o", context_wrapper)

        expected_input = [
          { role: "user", content: "What is your refund policy?" },
          { role: "assistant", content: { key: "value" }.to_json }
        ].to_json

        expect(tracer).to have_received(:start_span).with(
          "agents.run.generation",
          with_parent: anything,
          attributes: hash_including("langfuse.observation.input" => expected_input)
        )
      end
    end
  end

  describe "#on_tool_start" do
    before do
      allow(tracer).to receive(:start_span).and_return(root_span, agent_span)
      callbacks.on_run_start("TestAgent", "Hello", context_wrapper)
      callbacks.on_agent_thinking("TestAgent", "Hello", context_wrapper)
    end

    it "opens a child tool span with correct name under agent context" do
      allow(tracer).to receive(:start_span).and_return(tool_span)

      callbacks.on_tool_start("lookup_user", { user_id: 123 }, context_wrapper)

      agent_ctx = context_wrapper.context[:__otel_tracing][:current_agent_context]
      expect(tracer).to have_received(:start_span).with(
        "agents.run.tool.lookup_user",
        with_parent: agent_ctx,
        attributes: hash_including("langfuse.observation.type" => "tool")
      )
    end

    it "parents handoff tools under root context" do
      allow(tracer).to receive(:start_span).and_return(tool_span)

      callbacks.on_tool_start("handoff_to_billing", { reason: "billing question" }, context_wrapper)

      root_ctx = context_wrapper.context[:__otel_tracing][:root_context]
      expect(tracer).to have_received(:start_span).with(
        "agents.run.tool.handoff_to_billing",
        with_parent: root_ctx,
        attributes: hash_including("langfuse.observation.type" => "tool")
      )
    end

    it "does NOT set gen_ai.request.model on tool span" do
      allow(tracer).to receive(:start_span).and_return(tool_span)

      callbacks.on_tool_start("lookup_user", { user_id: 123 }, context_wrapper)

      expect(tracer).to have_received(:start_span).with(
        "agents.run.tool.lookup_user",
        with_parent: anything,
        attributes: hash_not_including("gen_ai.request.model")
      )
    end

    it "stores the tool span in tracing state" do
      allow(tracer).to receive(:start_span).and_return(tool_span)

      callbacks.on_tool_start("lookup_user", { user_id: 123 }, context_wrapper)

      expect(context_wrapper.context[:__otel_tracing][:current_tool_span]).to eq(tool_span)
    end

    context "without agent span" do
      before do
        tracing = context_wrapper.context[:__otel_tracing]
        tracing[:current_agent_name] = nil
        tracing[:current_agent_span] = nil
        tracing[:current_agent_context] = nil
      end

      it "falls back to root context for regular tools" do
        allow(tracer).to receive(:start_span).and_return(tool_span)

        callbacks.on_tool_start("lookup_user", { user_id: 123 }, context_wrapper)

        root_ctx = context_wrapper.context[:__otel_tracing][:root_context]
        expect(tracer).to have_received(:start_span).with(
          "agents.run.tool.lookup_user",
          with_parent: root_ctx,
          attributes: anything
        )
      end
    end
  end

  describe "#on_tool_complete" do
    before do
      allow(tracer).to receive(:start_span).and_return(root_span, agent_span, tool_span)
      callbacks.on_run_start("TestAgent", "Hello", context_wrapper)
      callbacks.on_agent_thinking("TestAgent", "Hello", context_wrapper)
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
        "agents.run.handoff",
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
      expect(root_span).to have_received(:set_attribute).with("langfuse.observation.output", "Final answer")
    end

    it "does not set output attributes when serialized output is empty" do
      empty_output_result = instance_double(Agents::RunResult, output: nil)

      callbacks.on_run_complete("TestAgent", empty_output_result, context_wrapper)

      expect(root_span).not_to have_received(:set_attribute).with("langfuse.trace.output", anything)
      expect(root_span).not_to have_received(:set_attribute).with("langfuse.observation.output", anything)
    end

    it "records run errors and marks the root span status as error" do
      run_error = StandardError.new("tool execution failed")
      error_result = instance_double(Agents::RunResult, output: nil, error: run_error)

      callbacks.on_run_complete("TestAgent", error_result, context_wrapper)

      expect(root_span).to have_received(:record_exception).with(run_error)
      expect(root_span).to have_received(:status=).with(
        having_attributes(description: "tool execution failed")
      )
    end

    it "finishes the root span" do
      callbacks.on_run_complete("TestAgent", run_result, context_wrapper)

      expect(root_span).to have_received(:finish)
    end

    it "cleans up tracing state from context" do
      callbacks.on_run_complete("TestAgent", run_result, context_wrapper)

      expect(context_wrapper.context[:__otel_tracing]).to be_nil
    end

    it "closes dangling agent span before closing root span" do
      allow(tracer).to receive(:start_span).and_return(agent_span)
      callbacks.on_agent_thinking("TestAgent", "Hello", context_wrapper)

      callbacks.on_run_complete("TestAgent", run_result, context_wrapper)

      expect(agent_span).to have_received(:finish)
      expect(root_span).to have_received(:finish)
    end
  end

  describe "#on_run_complete with dangling spans" do
    let(:run_result) { instance_double(Agents::RunResult, output: "error result") }

    context "with dangling tool span" do
      before do
        allow(tracer).to receive(:start_span).and_return(root_span, agent_span, tool_span)
        callbacks.on_run_start("TestAgent", "Hello", context_wrapper)
        callbacks.on_agent_thinking("TestAgent", "Hello", context_wrapper)
        callbacks.on_tool_start("failing_tool", { key: "val" }, context_wrapper)
      end

      it "closes dangling tool span before closing root span" do
        callbacks.on_run_complete("TestAgent", run_result, context_wrapper)

        expect(tool_span).to have_received(:finish)
        expect(agent_span).to have_received(:finish)
        expect(root_span).to have_received(:finish)
      end

      it "clears dangling tool span from tracing state" do
        expect(context_wrapper.context[:__otel_tracing][:current_tool_span]).to eq(tool_span)

        callbacks.on_run_complete("TestAgent", run_result, context_wrapper)

        expect(context_wrapper.context[:__otel_tracing]).to be_nil
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
