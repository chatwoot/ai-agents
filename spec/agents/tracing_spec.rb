# frozen_string_literal: true

RSpec.describe Agents::Tracing do
  before do
    # Reset tracing state before each test
    described_class.reset!
  end

  describe ".setup" do
    let(:config) do
      instance_double(
        Agents::Configuration,
        enable_tracing: true,
        tracing_endpoint: "http://localhost:4318/v1/traces",
        tracing_headers: { "Authorization" => "Bearer test_key" },
        app_name: "test-app",
        app_version: "1.0.0",
        environment: "test"
      )
    end

    context "when tracing is enabled" do
      it "initializes OpenTelemetry SDK" do
        described_class.setup(config)
        expect(described_class.enabled?).to be true
      end

      it "creates a tracer instance" do
        described_class.setup(config)
        expect(described_class.tracer).not_to be_nil
      end
    end

    context "when tracing is disabled" do
      before do
        allow(config).to receive(:enable_tracing).and_return(false)
      end

      it "does not enable tracing" do
        described_class.setup(config)
        expect(described_class.enabled?).to be false
      end
    end

    context "when reconfiguring" do
      let(:disabled_config) do
        instance_double(
          Agents::Configuration,
          enable_tracing: false
        )
      end

      it "disables tracing when reconfigured with enable_tracing: false" do
        # First enable tracing
        described_class.setup(config)
        expect(described_class.enabled?).to be true

        # Then disable it
        described_class.setup(disabled_config)
        expect(described_class.enabled?).to be false
      end
    end
  end

  describe ".with_trace" do
    context "when tracing is disabled" do
      it "executes block without tracing" do
        result = described_class.with_trace(user_id: "user_123") do
          "test_result"
        end

        expect(result).to eq("test_result")
      end

      it "does not create trace context" do
        described_class.with_trace(user_id: "user_123") {}
        expect(described_class.current_trace_context).to be_nil
      end
    end

    context "when tracing is enabled" do
      let(:config) do
        instance_double(
          Agents::Configuration,
          enable_tracing: true,
          tracing_endpoint: "http://localhost:4318/v1/traces",
          tracing_headers: {},
          app_name: "test-app",
          app_version: "1.0.0",
          environment: "test"
        )
      end

      before do
        described_class.setup(config)
      end

      it "creates trace context within block" do
        context_during_block = nil

        described_class.with_trace(user_id: "user_123") do
          context_during_block = described_class.current_trace_context
        end

        expect(context_during_block).not_to be_nil
        expect(context_during_block.user_id).to eq("user_123")
      end

      it "clears trace context after block" do
        described_class.with_trace(user_id: "user_123") {}
        expect(described_class.current_trace_context).to be_nil
      end

      it "returns block result" do
        result = described_class.with_trace(user_id: "user_123") do
          "test_result"
        end

        expect(result).to eq("test_result")
      end

      it "supports nested contexts" do
        outer_context = nil
        inner_context = nil

        described_class.with_trace(user_id: "user_123", tags: ["outer"]) do
          outer_context = described_class.current_trace_context

          described_class.with_trace(session_id: "session_abc", tags: ["inner"]) do
            inner_context = described_class.current_trace_context
          end
        end

        expect(outer_context.user_id).to eq("user_123")
        expect(outer_context.tags).to eq(["outer"])

        expect(inner_context.user_id).to eq("user_123") # inherited
        expect(inner_context.session_id).to eq("session_abc")
        expect(inner_context.tags).to eq(%w[outer inner]) # concatenated
      end
    end
  end

  describe ".in_span" do
    context "when tracing is disabled" do
      it "executes block without creating span" do
        result = described_class.in_span("test_span") do |span|
          expect(span).to be_a(Agents::Tracing::NoopSpan)
          "test_result"
        end

        expect(result).to eq("test_result")
      end
    end

    context "when tracing is enabled" do
      let(:config) do
        instance_double(
          Agents::Configuration,
          enable_tracing: true,
          tracing_endpoint: "http://localhost:4318/v1/traces",
          tracing_headers: {},
          app_name: "test-app",
          app_version: "1.0.0",
          environment: "test"
        )
      end

      before do
        described_class.setup(config)
      end

      it "creates span with default type" do
        described_class.in_span("test_span") do |span|
          expect(span).to respond_to(:set_attribute)
        end
      end

      it "creates span with custom type" do
        described_class.in_span("test_task", type: :task) do |span|
          expect(span).to respond_to(:set_attribute)
        end
      end

      it "returns block result" do
        result = described_class.in_span("test_span") do
          "test_result"
        end

        expect(result).to eq("test_result")
      end
    end
  end

  describe ".agent_span" do
    context "when tracing is disabled" do
      it "executes block without creating span" do
        result = described_class.agent_span("test_agent", model: "gpt-4") do |span|
          expect(span).to be_a(Agents::Tracing::NoopSpan)
          "test_result"
        end

        expect(result).to eq("test_result")
      end
    end

    context "when tracing is enabled" do
      let(:config) do
        instance_double(
          Agents::Configuration,
          enable_tracing: true,
          tracing_endpoint: "http://localhost:4318/v1/traces",
          tracing_headers: {},
          app_name: "test-app",
          app_version: "1.0.0",
          environment: "test"
        )
      end

      before do
        described_class.setup(config)
      end

      it "creates agent span with attributes" do
        described_class.agent_span("test_agent", model: "gpt-4") do |span|
          expect(span).to respond_to(:set_attribute)
        end
      end

      it "returns block result" do
        result = described_class.agent_span("test_agent", model: "gpt-4") do
          "test_result"
        end

        expect(result).to eq("test_result")
      end
    end
  end

  describe ".tool_span" do
    context "when tracing is disabled" do
      it "executes block without creating span" do
        result = described_class.tool_span("test_tool", arguments: { arg: "value" }) do |span|
          expect(span).to be_a(Agents::Tracing::NoopSpan)
          "test_result"
        end

        expect(result).to eq("test_result")
      end
    end

    context "when tracing is enabled" do
      let(:config) do
        instance_double(
          Agents::Configuration,
          enable_tracing: true,
          tracing_endpoint: "http://localhost:4318/v1/traces",
          tracing_headers: {},
          app_name: "test-app",
          app_version: "1.0.0",
          environment: "test"
        )
      end

      before do
        described_class.setup(config)
      end

      it "creates tool span with attributes" do
        described_class.tool_span("test_tool", arguments: { arg: "value" }) do |span|
          expect(span).to respond_to(:set_attribute)
        end
      end

      it "returns block result" do
        result = described_class.tool_span("test_tool", arguments: { arg: "value" }) do
          "test_result"
        end

        expect(result).to eq("test_result")
      end
    end
  end

  describe "NoopSpan" do
    subject(:noop_span) { Agents::Tracing::NoopSpan.new }

    it "provides no-op set_attribute" do
      expect { noop_span.set_attribute("key", "value") }.not_to raise_error
    end

    it "provides no-op add_event" do
      expect { noop_span.add_event("event_name") }.not_to raise_error
    end

    it "provides no-op status=" do
      expect { noop_span.status = "status" }.not_to raise_error
    end

    it "provides no-op record_exception" do
      expect { noop_span.record_exception(StandardError.new) }.not_to raise_error
    end
  end
end
