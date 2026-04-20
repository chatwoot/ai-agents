# frozen_string_literal: true

require_relative "../../lib/agents"

RSpec.describe Agents::GuardResult do
  describe ".pass" do
    it "creates a passing result" do
      result = described_class.pass
      expect(result.pass?).to be true
      expect(result.rewrite?).to be false
      expect(result.tripwire?).to be false
    end

    it "defaults message to empty string" do
      result = described_class.pass
      expect(result.message).to eq("")
    end

    it "accepts optional message and metadata" do
      result = described_class.pass(message: "all good", metadata: { score: 0.99 })
      expect(result.message).to eq("all good")
      expect(result.metadata).to eq({ score: 0.99 })
    end

    it "has nil content" do
      result = described_class.pass
      expect(result.content).to be_nil
    end
  end

  describe ".rewrite" do
    it "creates a rewrite result with replacement content" do
      result = described_class.rewrite("cleaned output")
      expect(result.rewrite?).to be true
      expect(result.pass?).to be false
      expect(result.tripwire?).to be false
      expect(result.content).to eq("cleaned output")
    end

    it "accepts optional message and metadata" do
      result = described_class.rewrite("redacted", message: "PII found", metadata: { count: 2 })
      expect(result.message).to eq("PII found")
      expect(result.metadata).to eq({ count: 2 })
    end

    it "allows empty string as content" do
      result = described_class.rewrite("")
      expect(result.rewrite?).to be true
      expect(result.content).to eq("")
    end
  end

  describe ".tripwire" do
    it "creates a tripwire result" do
      result = described_class.tripwire(message: "blocked")
      expect(result.tripwire?).to be true
      expect(result.pass?).to be false
      expect(result.rewrite?).to be false
    end

    it "stores the message" do
      result = described_class.tripwire(message: "Prompt injection detected")
      expect(result.message).to eq("Prompt injection detected")
    end

    it "has nil content" do
      result = described_class.tripwire(message: "blocked")
      expect(result.content).to be_nil
    end

    it "accepts optional metadata" do
      result = described_class.tripwire(message: "blocked", metadata: { pattern: "sql_injection" })
      expect(result.metadata).to eq({ pattern: "sql_injection" })
    end
  end

  describe "#initialize" do
    it "creates result with all fields" do
      result = described_class.new(
        action: :rewrite,
        content: "new content",
        message: "rewritten",
        metadata: { key: "value" }
      )
      expect(result.action).to eq(:rewrite)
      expect(result.content).to eq("new content")
      expect(result.message).to eq("rewritten")
      expect(result.metadata).to eq({ key: "value" })
    end

    it "defaults metadata to empty hash" do
      result = described_class.new(action: :pass)
      expect(result.metadata).to eq({})
    end

    it "defaults message to empty string" do
      result = described_class.new(action: :pass)
      expect(result.message).to eq("")
    end

    it "defaults output to content when not provided" do
      result = described_class.new(action: :rewrite, content: "text")
      expect(result.output).to eq("text")
    end

    it "stores output separately when provided" do
      result = described_class.new(action: :rewrite, content: '{"a":1}', output: { "a" => 1 })
      expect(result.content).to eq('{"a":1}')
      expect(result.output).to eq({ "a" => 1 })
    end
  end
end
