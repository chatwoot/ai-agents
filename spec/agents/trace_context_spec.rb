# frozen_string_literal: true

RSpec.describe Agents::TraceContext do
  describe "#initialize" do
    context "with all parameters" do
      it "stores all trace metadata" do
        context = described_class.new(
          user_id: "user_123",
          session_id: "session_abc",
          trace_name: "test_trace",
          tags: %w[tag1 tag2],
          metadata: { key: "value" }
        )

        expect(context.user_id).to eq("user_123")
        expect(context.session_id).to eq("session_abc")
        expect(context.trace_name).to eq("test_trace")
        expect(context.tags).to eq(%w[tag1 tag2])
        expect(context.metadata).to eq({ key: "value" })
      end
    end

    context "with minimal parameters" do
      it "uses default values for optional fields" do
        context = described_class.new

        expect(context.user_id).to be_nil
        expect(context.session_id).to be_nil
        expect(context.trace_name).to be_nil
        expect(context.tags).to eq([])
        expect(context.metadata).to eq({})
      end
    end

    context "with nil tags" do
      it "converts nil to empty array" do
        context = described_class.new(tags: nil)
        expect(context.tags).to eq([])
      end
    end

    context "with nil metadata" do
      it "converts nil to empty hash" do
        context = described_class.new(metadata: nil)
        expect(context.metadata).to eq({})
      end
    end
  end

  describe "#merge" do
    let(:parent_context) do
      described_class.new(
        user_id: "user_123",
        session_id: "session_abc",
        trace_name: "parent_trace",
        tags: ["parent_tag"],
        metadata: { parent_key: "parent_value", shared_key: "parent" }
      )
    end

    context "when child overrides user_id" do
      it "uses child's user_id" do
        child = described_class.new(user_id: "user_456")
        merged = parent_context.merge(child)

        expect(merged.user_id).to eq("user_456")
      end
    end

    context "when child does not override user_id" do
      it "uses parent's user_id" do
        child = described_class.new(session_id: "session_xyz")
        merged = parent_context.merge(child)

        expect(merged.user_id).to eq("user_123")
      end
    end

    context "when child overrides session_id" do
      it "uses child's session_id" do
        child = described_class.new(session_id: "session_xyz")
        merged = parent_context.merge(child)

        expect(merged.session_id).to eq("session_xyz")
      end
    end

    context "when child overrides trace_name" do
      it "uses child's trace_name" do
        child = described_class.new(trace_name: "child_trace")
        merged = parent_context.merge(child)

        expect(merged.trace_name).to eq("child_trace")
      end
    end

    context "with tags" do
      it "concatenates parent and child tags" do
        child = described_class.new(tags: ["child_tag"])
        merged = parent_context.merge(child)

        expect(merged.tags).to eq(%w[parent_tag child_tag])
      end
    end

    context "with metadata" do
      it "deep merges metadata" do
        child = described_class.new(
          metadata: { child_key: "child_value", shared_key: "child" }
        )
        merged = parent_context.merge(child)

        expect(merged.metadata).to eq({
                                        parent_key: "parent_value",
                                        child_key: "child_value",
                                        shared_key: "child"
                                      })
      end
    end

    context "with nested metadata" do
      it "deep merges nested hashes" do
        parent = described_class.new(
          metadata: { nested: { a: 1, b: 2 }, top: "parent" }
        )
        child = described_class.new(
          metadata: { nested: { b: 3, c: 4 }, top: "child" }
        )
        merged = parent.merge(child)

        expect(merged.metadata).to eq({
                                        nested: { a: 1, b: 3, c: 4 },
                                        top: "child"
                                      })
      end
    end
  end

  describe "#to_otel_attributes" do
    context "with complete trace context" do
      it "converts to OpenTelemetry attributes" do
        context = described_class.new(
          user_id: "user_123",
          session_id: "session_abc",
          tags: %w[tag1 tag2],
          metadata: { tier: "premium", region: "us-east" }
        )

        attributes = context.to_otel_attributes

        expect(attributes).to include(
          "user.id" => "user_123",
          "langfuse.user.id" => "user_123",
          "session.id" => "session_abc",
          "langfuse.session.id" => "session_abc",
          "langfuse.trace.tags" => "tag1,tag2",
          "langfuse.trace.metadata.tier" => "premium",
          "langfuse.trace.metadata.region" => "us-east"
        )
      end
    end

    context "without user_id" do
      it "omits user attributes" do
        context = described_class.new(session_id: "session_abc")
        attributes = context.to_otel_attributes

        expect(attributes).not_to have_key("user.id")
        expect(attributes).not_to have_key("langfuse.user.id")
      end
    end

    context "without session_id" do
      it "omits session attributes" do
        context = described_class.new(user_id: "user_123")
        attributes = context.to_otel_attributes

        expect(attributes).not_to have_key("session.id")
        expect(attributes).not_to have_key("langfuse.session.id")
      end
    end

    context "without tags" do
      it "omits tags attribute" do
        context = described_class.new(user_id: "user_123")
        attributes = context.to_otel_attributes

        expect(attributes).not_to have_key("langfuse.trace.tags")
      end
    end

    context "with empty metadata" do
      it "does not include metadata attributes" do
        context = described_class.new(user_id: "user_123")
        attributes = context.to_otel_attributes

        metadata_keys = attributes.keys.select { |k| k.start_with?("langfuse.trace.metadata.") }
        expect(metadata_keys).to be_empty
      end
    end

    context "with metadata values that need conversion" do
      it "converts metadata values to strings" do
        context = described_class.new(
          metadata: { count: 42, enabled: true, name: "test" }
        )
        attributes = context.to_otel_attributes

        expect(attributes["langfuse.trace.metadata.count"]).to eq("42")
        expect(attributes["langfuse.trace.metadata.enabled"]).to eq("true")
        expect(attributes["langfuse.trace.metadata.name"]).to eq("test")
      end
    end
  end

  describe "#empty?" do
    context "with no trace information" do
      it "returns true" do
        context = described_class.new
        expect(context.empty?).to be true
      end
    end

    context "with user_id" do
      it "returns false" do
        context = described_class.new(user_id: "user_123")
        expect(context.empty?).to be false
      end
    end

    context "with session_id" do
      it "returns false" do
        context = described_class.new(session_id: "session_abc")
        expect(context.empty?).to be false
      end
    end

    context "with trace_name" do
      it "returns false" do
        context = described_class.new(trace_name: "test_trace")
        expect(context.empty?).to be false
      end
    end

    context "with tags" do
      it "returns false" do
        context = described_class.new(tags: ["tag1"])
        expect(context.empty?).to be false
      end
    end

    context "with metadata" do
      it "returns false" do
        context = described_class.new(metadata: { key: "value" })
        expect(context.empty?).to be false
      end
    end
  end
end
