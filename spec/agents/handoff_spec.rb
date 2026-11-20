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

    context "with special characters in agent name" do
      it "strips special characters from tool name" do
        agent = instance_double(Agents::Agent, name: "Billing-Agent!")
        tool = described_class.new(agent)

        expect(tool.name).to eq("handoff_to_billingagent")
      end
    end

    it "sets description for handoff" do
      expected_description = "Transfer conversation to Support Agent"
      expect(handoff_tool.description).to eq(expected_description)
    end
  end

  describe "#perform" do
    let(:context_hash) { {} }
    let(:tool_context) do
      instance_double(Agents::ToolContext, run_context: instance_double(Agents::RunContext, context: context_hash))
    end

    it "records the pending handoff" do
      handoff_tool.perform(tool_context)

      expect(context_hash[:pending_handoff]).to include(target_agent: target_agent)
    end

    it "names the agent that handed over the conversation" do
      source_agent = instance_double(Agents::Agent, name: "Triage Agent")
      tool = described_class.new(target_agent, source_agent: source_agent)

      expect(tool.perform(tool_context)).to eq("Triage Agent handed this conversation to Support Agent.")
    end

    it "names only the target when no source agent is given" do
      expect(handoff_tool.perform(tool_context)).to eq("This conversation was handed to Support Agent.")
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
