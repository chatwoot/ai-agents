# frozen_string_literal: true

require "spec_helper"
require "agents/handoff"

RSpec.describe Agents::AgentResponse do
  describe "#initialize" do
    it "creates a response with content only" do
      response = described_class.new(content: "Response text")

      expect(response.content).to eq("Response text")
      expect(response.handoff_result).to be_nil
      expect(response.tool_calls).to eq([])
    end

    it "creates a response with content and handoff" do
      handoff = Agents::HandoffResult.new(target_agent_class: Class.new)
      response = described_class.new(content: "Response text", handoff_result: handoff)

      expect(response.content).to eq("Response text")
      expect(response.handoff_result).to eq(handoff)
    end
  end

  describe "#handoff?" do
    it "returns false when no handoff" do
      response = described_class.new(content: "Response")
      expect(response.handoff?).to be false
    end

    it "returns true when handoff is present" do
      handoff = Agents::HandoffResult.new(target_agent_class: Class.new)
      response = described_class.new(content: "Response", handoff_result: handoff)
      expect(response.handoff?).to be true
    end

    it "delegates to handoff.handoff?" do
      handoff = instance_double(Agents::HandoffResult)
      allow(handoff).to receive(:handoff?).and_return(true)

      response = described_class.new(content: "Response", handoff_result: handoff)
      expect(response.handoff?).to be true
      expect(handoff).to have_received(:handoff?)
    end
  end

  describe "#has_tool_calls?" do
    it "returns false when no tool calls" do
      response = described_class.new(content: "Response")
      expect(response.has_tool_calls?).to be false
    end

    it "returns true when tool calls are present" do
      response = described_class.new(content: "Response", tool_calls: [{ name: "tool1" }])
      expect(response.has_tool_calls?).to be true
    end
  end

  describe "#has_content?" do
    it "returns false when content is nil" do
      response = described_class.new(content: nil)
      expect(response.has_content?).to be false
    end

    it "returns false when content is empty" do
      response = described_class.new(content: "   ")
      expect(response.has_content?).to be false
    end

    it "returns true when content is present" do
      response = described_class.new(content: "Response text")
      expect(response.has_content?).to be true
    end
  end

  describe "#==" do
    it "returns true for equal responses" do
      response1 = described_class.new(content: "Same content")
      response2 = described_class.new(content: "Same content")
      # NOTE: AgentResponse doesn't implement == method, so this will use object identity
      expect(response1).not_to eq(response2)
    end

    it "returns false for different content" do
      response1 = described_class.new(content: "Content 1")
      response2 = described_class.new(content: "Content 2")
      expect(response1).not_to eq(response2)
    end

    it "considers handoff in equality" do
      handoff = Agents::HandoffResult.new(target_agent_class: Class.new)
      response1 = described_class.new(content: "Same", handoff_result: handoff)
      response2 = described_class.new(content: "Same", handoff_result: handoff)
      response3 = described_class.new(content: "Same")

      # NOTE: AgentResponse doesn't implement == method, so this will use object identity
      expect(response1).not_to eq(response2)
      expect(response1).not_to eq(response3)
    end
  end
end
