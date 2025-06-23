# frozen_string_literal: true

require "spec_helper"
require "agents/handoff"
require "agents/agent"
require "agents/context"

RSpec.describe "Handoff Components" do
  describe Agents::HandoffResult do
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

  describe Agents::AgentResponse do
    describe "#initialize" do
      it "creates a response with content only" do
        response = described_class.new(content: "Response text")

        expect(response.content).to eq("Response text")
        expect(response.handoff).to be_nil
      end

      it "creates a response with content and handoff" do
        handoff = Agents::HandoffResult.new(target_agent_class: Class.new)
        response = described_class.new(content: "Response text", handoff: handoff)

        expect(response.content).to eq("Response text")
        expect(response.handoff).to eq(handoff)
      end
    end

    describe "#handoff?" do
      it "returns false when no handoff" do
        response = described_class.new(content: "Response")
        expect(response.handoff?).to be false
      end

      it "returns true when handoff is present" do
        handoff = Agents::HandoffResult.new(target_agent_class: Class.new)
        response = described_class.new(content: "Response", handoff: handoff)
        expect(response.handoff?).to be true
      end

      it "delegates to handoff.handoff?" do
        handoff = instance_double(Agents::HandoffResult)
        expect(handoff).to receive(:handoff?).and_return(true)

        response = described_class.new(content: "Response", handoff: handoff)
        expect(response.handoff?).to be true
      end
    end

    describe "#to_h" do
      it "returns hash representation without handoff" do
        response = described_class.new(content: "Response text")
        expect(response.to_h).to eq({ content: "Response text" })
      end

      it "returns hash representation with handoff" do
        target_class = Class.new
        handoff = Agents::HandoffResult.new(
          target_agent_class: target_class,
          reason: "Transfer needed",
          context: { key: "value" }
        )
        response = described_class.new(content: "Response text", handoff: handoff)

        hash = response.to_h
        expect(hash[:content]).to eq("Response text")
        expect(hash[:handoff]).to eq({
                                       target_agent_class: target_class,
                                       reason: "Transfer needed",
                                       context: { key: "value" }
                                     })
      end
    end

    describe "#==" do
      it "returns true for equal responses" do
        response1 = described_class.new(content: "Same content")
        response2 = described_class.new(content: "Same content")
        expect(response1).to eq(response2)
      end

      it "returns false for different content" do
        response1 = described_class.new(content: "Content 1")
        response2 = described_class.new(content: "Content 2")
        expect(response1).not_to eq(response2)
      end

      it "considers handoff in equality" do
        handoff = Agents::HandoffResult.new(target_agent_class: Class.new)
        response1 = described_class.new(content: "Same", handoff: handoff)
        response2 = described_class.new(content: "Same", handoff: handoff)
        response3 = described_class.new(content: "Same")

        expect(response1).to eq(response2)
        expect(response1).not_to eq(response3)
      end
    end
  end

  describe Agents::HandoffTool do
    # Test agent classes
    let(:test_target_agent_class) do
      Class.new(Agents::Agent) do
        name "Test Target"
      end
    end
    let(:context) { Agents::Context.new }

    let(:complex_name_agent_class) do
      Class.new(Agents::Agent) do
        name "Complex Name Agent"
      end
    end

    before do
      stub_const("TestTargetAgent", test_target_agent_class)
      stub_const("ComplexNameAgent", complex_name_agent_class)
    end

    describe "#initialize" do
      it "creates a handoff tool with default description" do
        tool = described_class.new(TestTargetAgent)

        expect(tool.target_agent_class).to eq(TestTargetAgent)
        expect(tool.name).to eq("transfer_to_test_target_agent")
        expect(tool.description).to eq("Transfer to Test Target")
      end

      it "creates a handoff tool with custom description" do
        tool = described_class.new(TestTargetAgent, description: "Custom transfer")

        expect(tool.description).to eq("Custom transfer")
      end

      it "handles complex class names correctly" do
        tool = described_class.new(ComplexNameAgent)

        expect(tool.name).to eq("transfer_to_complex_name_agent")
      end

      it "handles namespaced classes" do
        namespaced_agent_class = Class.new(Agents::Agent) do
          name "Namespaced"
        end
        stub_const("TestNamespace::NamespacedAgent", namespaced_agent_class)

        tool = described_class.new(TestNamespace::NamespacedAgent)
        expect(tool.name).to eq("transfer_to_namespaced_agent")
      end
    end

    describe "#perform" do
      let(:tool) { described_class.new(TestTargetAgent) }

      it "sets pending_handoff in context" do
        result = tool.perform(reason: "User requested", context: context)

        expect(context[:pending_handoff]).to be_a(Agents::HandoffResult)
        expect(context[:pending_handoff].target_agent_class).to eq(TestTargetAgent)
        expect(context[:pending_handoff].reason).to eq("User requested")
        expect(result).to eq("Transferring to Test Target: User requested")
      end

      it "works without a reason" do
        result = tool.perform(context: context)

        expect(context[:pending_handoff]).to be_a(Agents::HandoffResult)
        expect(context[:pending_handoff].target_agent_class).to eq(TestTargetAgent)
        expect(context[:pending_handoff].reason).to be_nil
        expect(result).to eq("Transferring to Test Target")
      end
    end

    describe "#target_agent" do
      it "returns the target agent class" do
        tool = described_class.new(TestTargetAgent)
        expect(tool.target_agent).to eq(TestTargetAgent)
      end
    end

    describe "#to_json_schema" do
      it "includes reason parameter in schema" do
        tool = described_class.new(TestTargetAgent)
        schema = tool.to_json_schema

        expect(schema[:name]).to eq("transfer_to_test_target_agent")
        expect(schema[:description]).to eq("Transfer to Test Target")
        expect(schema[:parameters][:properties]).to have_key(:reason)
        expect(schema[:parameters][:properties][:reason][:type]).to eq("string")
      end
    end
  end
end
