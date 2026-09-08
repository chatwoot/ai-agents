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
    it "records the target and returns a normal tool result" do
      tool_context = Agents::ToolContext.new(run_context: Agents::RunContext.new(context))

      expect(handoff_tool.perform(tool_context)).to eq("Transferring to Support Agent")
      expect(context[:pending_handoff]).to eq(target_agent: target_agent.name)
    end

    it "keeps the first handoff when several tools request one" do
      tool_context = Agents::ToolContext.new(run_context: Agents::RunContext.new(context))
      handoff_tool.perform(tool_context)
      another = described_class.new(Agents::Agent.new(name: "Billing"))

      expect(another.perform(tool_context)).to eq("Handoff already requested")
      expect(context[:pending_handoff]).to eq(target_agent: target_agent.name)
    end
  end

  describe "#target_agent" do
    it "returns the target agent" do
      expect(handoff_tool.target_agent).to be(target_agent)
    end
  end
end
