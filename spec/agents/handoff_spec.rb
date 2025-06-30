# frozen_string_literal: true

require_relative "../../lib/agents"

RSpec.describe Agents::HandoffTool do
  let(:target_agent) { instance_double(Agents::Agent, name: "Support Agent") }
  let(:handoff_tool) { described_class.new(target_agent) }
  let(:context) { {} }

  describe "#initialize" do
    it "creates handoff tool with target agent" do
      expect(handoff_tool.target_agent).to eq(target_agent)
    end

    it "sets tool name based on target agent" do
      expect(handoff_tool.name).to eq("handoff_to_support_agent")
    end

    it "sets description for handoff" do
      expected_description = "Transfer conversation to Support Agent"
      expect(handoff_tool.description).to eq(expected_description)
    end
  end

  describe "#perform" do
    it "returns transfer message" do
      result = handoff_tool.perform(nil)

      expect(result).to eq("I'll transfer you to Support Agent who can better assist you with this.")
    end
  end

  describe "#target_agent" do
    it "returns the target agent" do
      expect(handoff_tool.target_agent).to be(target_agent)
    end
  end
end

# TODO: HandoffResult and AgentResponse classes need to be implemented
# These were referenced in the original design but aren't part of current implementation
