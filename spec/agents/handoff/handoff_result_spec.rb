# frozen_string_literal: true

require "spec_helper"
require "agents/handoff"

RSpec.describe Agents::HandoffResult do
  describe "#initialize" do
    it "creates a handoff result with required parameters" do
      target_class = Class.new
      result = described_class.new(target_agent_class: target_class)

      expect(result.target_agent_class).to eq(target_class)
      expect(result.reason).to be_nil
      expect(result.context).to be_nil
    end

    it "creates a handoff result with all parameters" do
      target_class = Class.new
      context = { key: "value" }
      result = described_class.new(
        target_agent_class: target_class,
        reason: "User requested",
        context: context
      )

      expect(result.target_agent_class).to eq(target_class)
      expect(result.reason).to eq("User requested")
      expect(result.context).to eq(context)
    end
  end

  describe "#handoff?" do
    it "returns true when target_agent_class is present" do
      result = described_class.new(target_agent_class: Class.new)
      expect(result.handoff?).to be true
    end

    it "returns false when target_agent_class is nil" do
      result = described_class.new(target_agent_class: nil)
      expect(result.handoff?).to be false
    end
  end
end
