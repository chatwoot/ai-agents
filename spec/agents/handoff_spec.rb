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

    it "allows subclasses to configure their description with the tool DSL" do
      custom_tool_class = Class.new(described_class) do
        description "Transfer with structured context"
      end

      expect(custom_tool_class.new(target_agent).description).to eq("Transfer with structured context")
    end

    it "accepts explicit name and description overrides" do
      tool = described_class.new(target_agent, name: "delegate_support", description: "Delegate to support")

      expect(tool.name).to eq("delegate_support")
      expect(tool.description).to eq("Delegate to support")
    end
  end

  describe "#perform" do
    it "returns halt with transfer message" do
      run_context = Agents::RunContext.new({})
      tool_context = Agents::ToolContext.new(run_context: run_context)

      result = handoff_tool.perform(tool_context)

      expect(result).to be_a(RubyLLM::Tool::Halt)
      expect(result.content).to eq("I'll transfer you to Support Agent who can better assist you with this.")
      expect(run_context.context[:pending_handoff]).to include(target_agent: target_agent)
    end

    it "allows subclasses to attach a reason, metadata, and custom halt message" do
      structured_tool_class = Class.new(described_class) do
        def perform(tool_context)
          prepare_handoff(
            tool_context,
            reason: "Needs billing expertise",
            metadata: { account_id: 123 },
            message: "Routing to billing"
          )
        end
      end
      run_context = Agents::RunContext.new({})
      tool_context = Agents::ToolContext.new(run_context: run_context)

      result = structured_tool_class.new(target_agent).perform(tool_context)

      expect(result).to be_a(RubyLLM::Tool::Halt)
      expect(result.content).to eq("Routing to billing")
      expect(run_context.context[:pending_handoff]).to include(
        target_agent: target_agent,
        reason: "Needs billing expertise",
        metadata: { account_id: 123 }
      )
    end

    it "keeps the first accepted handoff when multiple wrappers execute concurrently" do
      other_agent = instance_double(Agents::Agent, name: "Billing Agent")
      run_context = Agents::RunContext.new({})
      wrappers = [handoff_tool, described_class.new(other_agent)].map do |tool|
        Agents::ToolWrapper.new(tool, run_context)
      end
      ready, start, results = 3.times.map { Queue.new }
      threads = wrappers.map do |wrapper|
        Thread.new do
          ready << true
          start.pop
          results << wrapper.call({})
        end
      end
      wrappers.size.times { ready.pop }
      wrappers.size.times { start << true }
      threads.each(&:join)

      halt_count = wrappers.size.times.count { results.pop.is_a?(RubyLLM::Tool::Halt) }

      expect(halt_count).to eq(1)
      expect([target_agent, other_agent]).to include(run_context.context[:pending_handoff][:target_agent])
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
