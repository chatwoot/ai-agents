# frozen_string_literal: true

require "spec_helper"
require "agents/handoff"
require "agents/agent"
require "agents/context"

RSpec.describe Agents::HandoffTool do
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

      expect(context[:pending_handoff]).to be_a(Hash)
      expect(context[:pending_handoff][:target_agent_class]).to eq(TestTargetAgent)
      expect(context[:pending_handoff][:reason]).to eq("User requested")

      expect(result).to be_a(Hash)
      expect(result[:type]).to eq("handoff")
      expect(result[:target]).to eq("Test Target")
      expect(result[:target_class]).to eq(TestTargetAgent)
      expect(result[:reason]).to eq("User requested")
      expect(result[:message]).to eq("Transferring to Test Target (User requested)...")
    end

    it "works without a reason" do
      result = tool.perform(context: context)

      expect(context[:pending_handoff]).to be_a(Hash)
      expect(context[:pending_handoff][:target_agent_class]).to eq(TestTargetAgent)
      expect(context[:pending_handoff][:reason]).to be_nil

      expect(result).to be_a(Hash)
      expect(result[:type]).to eq("handoff")
      expect(result[:target]).to eq("Test Target")
      expect(result[:target_class]).to eq(TestTargetAgent)
      expect(result[:reason]).to be_nil
      expect(result[:message]).to eq("Transferring to Test Target...")
    end
  end

  describe "#target_agent" do
    it "returns the target agent class" do
      tool = described_class.new(TestTargetAgent)
      expect(tool.target_agent_class).to eq(TestTargetAgent)
    end
  end

  describe "#name and #description" do
    it "provides correct tool metadata" do
      tool = described_class.new(TestTargetAgent)

      expect(tool.name).to eq("transfer_to_test_target_agent")
      expect(tool.description).to eq("Transfer to Test Target")
    end
  end
end
