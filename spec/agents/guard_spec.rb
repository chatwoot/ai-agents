# frozen_string_literal: true

require_relative "../../lib/agents"

RSpec.describe Agents::Guard do
  describe "#call" do
    it "raises NotImplementedError when not implemented" do
      guard = described_class.new
      expect { guard.call("content", nil) }.to raise_error(NotImplementedError, /Guards must implement/)
    end
  end

  describe ".guard_name" do
    it "defaults to the class name's last segment" do
      stub_const("MyApp::PiiRedactor", Class.new(described_class))
      expect(MyApp::PiiRedactor.guard_name).to eq("PiiRedactor")
    end

    it "can be set explicitly" do
      guard_class = Class.new(described_class) do
        guard_name "custom_guard"
      end
      expect(guard_class.guard_name).to eq("custom_guard")
    end

    it "is accessible via instance #name" do
      guard_class = Class.new(described_class) do
        guard_name "my_guard"
      end
      expect(guard_class.new.name).to eq("my_guard")
    end
  end

  describe ".description" do
    it "defaults to nil" do
      guard_class = Class.new(described_class)
      expect(guard_class.description).to be_nil
    end

    it "can be set explicitly" do
      guard_class = Class.new(described_class) do
        description "Detects prompt injection"
      end
      expect(guard_class.description).to eq("Detects prompt injection")
    end
  end

  describe "subclass implementation" do
    let(:passing_guard_class) do
      Class.new(described_class) do
        guard_name "passing_guard"

        def call(_content, _context)
          nil # pass
        end
      end
    end

    let(:rewriting_guard_class) do
      Class.new(described_class) do
        guard_name "rewriter"

        def call(content, _context)
          Agents::GuardResult.rewrite(content.upcase, message: "uppercased")
        end
      end
    end

    let(:tripwire_guard_class) do
      Class.new(described_class) do
        guard_name "blocker"

        def call(_content, _context)
          Agents::GuardResult.tripwire(message: "blocked")
        end
      end
    end

    it "can return nil to pass" do
      result = passing_guard_class.new.call("hello", nil)
      expect(result).to be_nil
    end

    it "can return a rewrite result" do
      result = rewriting_guard_class.new.call("hello", nil)
      expect(result.rewrite?).to be true
      expect(result.content).to eq("HELLO")
    end

    it "can return a tripwire result" do
      result = tripwire_guard_class.new.call("hello", nil)
      expect(result.tripwire?).to be true
    end
  end

  describe Agents::Guard::Tripwire do
    it "is a StandardError" do
      expect(described_class.superclass).to eq(StandardError)
    end

    it "stores guard_name and metadata" do
      error = described_class.new("blocked", guard_name: "pii_guard", metadata: { score: 0.95 })
      expect(error.message).to eq("blocked")
      expect(error.guard_name).to eq("pii_guard")
      expect(error.metadata).to eq({ score: 0.95 })
    end

    it "defaults metadata to empty hash" do
      error = described_class.new("blocked", guard_name: "test")
      expect(error.metadata).to eq({})
    end
  end
end
