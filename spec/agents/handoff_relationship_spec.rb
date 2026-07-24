# frozen_string_literal: true

require_relative "../../lib/agents"

RSpec.describe Agents::Handoff do
  let(:source_agent) { instance_double(Agents::Agent, name: "Triage") }
  let(:target_agent) { instance_double(Agents::Agent, name: "Billing") }

  describe "#build_tool" do
    it "builds the default handoff tool when no factory is configured" do
      relationship = described_class.new(target_agent)

      tool = relationship.build_tool(source_agent: source_agent)

      expect(tool).to be_a(Agents::HandoffTool)
      expect(tool.target_agent).to be(target_agent)
    end

    it "builds a custom handoff tool with source and target agents" do
      custom_tool_class = Class.new(Agents::HandoffTool)
      received_source = nil
      factory = lambda do |source_agent:, target_agent:|
        received_source = source_agent
        custom_tool_class.new(target_agent)
      end
      relationship = described_class.new(target_agent, tool_factory: factory)

      tool = relationship.build_tool(source_agent: source_agent)

      expect(tool).to be_a(custom_tool_class)
      expect(tool.target_agent).to be(target_agent)
      expect(received_source).to be(source_agent)
    end

    it "rejects tools that do not implement the handoff contract" do
      factory = ->(**) { Agents::Tool.new }
      relationship = described_class.new(target_agent, tool_factory: factory)

      expect { relationship.build_tool(source_agent: source_agent) }
        .to raise_error(ArgumentError, /Agents::HandoffTool/)
    end

    it "rejects tools configured for a different target" do
      other_agent = instance_double(Agents::Agent, name: "Support")
      factory = ->(**) { Agents::HandoffTool.new(other_agent) }
      relationship = described_class.new(target_agent, tool_factory: factory)

      expect { relationship.build_tool(source_agent: source_agent) }
        .to raise_error(ArgumentError, /registered target agent/)
    end
  end

  describe "#call_hook" do
    it "passes the run context and handoff information to the hook" do
      calls = []
      hook = ->(context, handoff_info) { calls << [context, handoff_info] }
      relationship = described_class.new(target_agent, on_handoff: hook)
      run_context = Agents::RunContext.new({})
      handoff_info = { target_agent: target_agent, metadata: { account_id: 123 } }

      relationship.call_hook(run_context, handoff_info)

      expect(calls).to eq([[run_context, handoff_info]])
    end

    it "does nothing when no hook is configured" do
      relationship = described_class.new(target_agent)

      expect { relationship.call_hook(Agents::RunContext.new({}), {}) }.not_to raise_error
    end
  end

  describe "validation" do
    it "rejects a non-callable tool factory" do
      expect { described_class.new(target_agent, tool_factory: "invalid") }
        .to raise_error(ArgumentError, /tool_factory/)
    end

    it "rejects a non-callable handoff hook" do
      expect { described_class.new(target_agent, on_handoff: "invalid") }
        .to raise_error(ArgumentError, /on_handoff/)
    end
  end
end
