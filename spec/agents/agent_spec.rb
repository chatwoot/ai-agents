# frozen_string_literal: true

require_relative "../../lib/agents"

RSpec.describe Agents::Agent do
  let(:test_tool) { instance_double(Agents::Tool, "TestTool") }
  let(:other_agent) { instance_double(Agents::Agent, name: "Other Agent") }
  let(:context) { double("Context") }

  describe "#initialize" do
    it "creates agent with required name parameter" do
      agent = described_class.new(name: "Test Agent")

      expect(agent.name).to eq("Test Agent")
      expect(agent.instructions).to be_nil
      expect(agent.model).to eq("gpt-4.1-mini")
      expect(agent.tools).to eq([])
      expect(agent.handoff_agents).to eq([])
    end

    it "creates agent with all parameters" do
      instructions = "You are a test agent"
      tools = [test_tool]
      handoff_agents = [other_agent]

      agent = described_class.new(
        name: "Test Agent",
        instructions: instructions,
        model: "gpt-4o",
        tools: tools,
        handoff_agents: handoff_agents
      )

      expect(agent.name).to eq("Test Agent")
      expect(agent.instructions).to eq(instructions)
      expect(agent.model).to eq("gpt-4o")
      expect(agent.tools).to eq(tools)
      expect(agent.handoff_agents).to include(other_agent)
    end

    it "creates agent with Proc instructions" do
      instructions_proc = proc { |_ctx| "Dynamic instructions" }

      agent = described_class.new(
        name: "Test Agent",
        instructions: instructions_proc
      )

      expect(agent.instructions).to eq(instructions_proc)
    end

    it "duplicates tools array to prevent mutation" do
      tools = [test_tool]
      agent = described_class.new(name: "Test", tools: tools)

      tools << instance_double(Agents::Tool, "AnotherTool")

      expect(agent.tools.size).to eq(1)
    end
  end

  describe "#register_handoffs" do
    let(:agent) { described_class.new(name: "Test Agent") }
    let(:agent1) { instance_double(Agents::Agent, "Agent1") }
    let(:agent2) { instance_double(Agents::Agent, "Agent2") }

    it "registers single handoff agent" do
      result = agent.register_handoffs(agent1)

      expect(agent.handoff_agents).to include(agent1)
      expect(result).to eq(agent)
    end

    it "registers multiple handoff agents" do
      agent.register_handoffs(agent1, agent2)

      expect(agent.handoff_agents).to include(agent1, agent2)
    end

    it "prevents duplicate handoff agents" do
      agent.register_handoffs(agent1, agent1)

      expect(agent.handoff_agents.count(agent1)).to eq(1)
    end

    it "is thread-safe with concurrent registrations" do
      agents = 10.times.map { instance_double(Agents::Agent, "Agent#{_1}") }

      threads = agents.map do |test_agent|
        Thread.new { agent.register_handoffs(test_agent) }
      end
      threads.each(&:join)

      expect(agent.handoff_agents.size).to eq(10)
    end

    it "returns self for method chaining" do
      result = agent.register_handoffs(agent1)

      expect(result).to be(agent)
    end
  end

  describe "#all_tools" do
    let(:agent) { described_class.new(name: "Test Agent", tools: [test_tool]) }
    let(:handoff_agent) { instance_double(Agents::Agent, name: "Handoff Agent") }

    it "returns regular tools when no handoffs registered" do
      expect(agent.all_tools).to eq([test_tool])
    end

    it "returns tools plus handoff tools" do
      agent.register_handoffs(handoff_agent)
      all_tools = agent.all_tools

      expect(all_tools).to include(test_tool)
      expect(all_tools.size).to eq(2)
      expect(all_tools.last).to be_a(Agents::HandoffTool)
    end

    it "is thread-safe" do
      threads = []
      5.times do |i|
        threads << Thread.new do
          agent.register_handoffs(instance_double(described_class, name: "Agent#{i}"))
          agent.all_tools
        end
      end
      threads.each(&:join)

      expect(agent.all_tools.size).to eq(6) # 1 regular + 5 handoff tools
    end
  end

  describe "#clone" do
    let(:original_agent) do
      described_class.new(
        name: "Original",
        instructions: "Original instructions",
        model: "gpt-4",
        tools: [test_tool],
        handoff_agents: [other_agent]
      )
    end

    it "creates new agent with same attributes when no changes provided" do
      cloned = original_agent.clone

      expect(cloned).not_to be(original_agent)
      expect(cloned.name).to eq("Original")
      expect(cloned.instructions).to eq("Original instructions")
      expect(cloned.model).to eq("gpt-4")
      expect(cloned.tools).to eq([test_tool])
      expect(cloned.handoff_agents).to eq([other_agent])
    end

    it "overrides specific attributes" do
      cloned = original_agent.clone(
        name: "Cloned",
        model: "gpt-3.5-turbo"
      )

      expect(cloned.name).to eq("Cloned")
      expect(cloned.model).to eq("gpt-3.5-turbo")
      expect(cloned.instructions).to eq("Original instructions")
      expect(cloned.tools).to eq([test_tool])
    end

    it "duplicates tools array to prevent mutation" do
      cloned = original_agent.clone
      cloned.tools << instance_double(Agents::Tool, "NewTool")

      expect(original_agent.tools.size).to eq(1)
    end
  end

  describe "#get_system_prompt" do
    it "returns static string instructions" do
      agent = described_class.new(
        name: "Test",
        instructions: "You are a test agent"
      )

      result = agent.get_system_prompt(context)
      expect(result).to eq("You are a test agent")
    end

    it "executes Proc instructions with context" do
      instructions_proc = proc { |ctx| "Dynamic: #{ctx}" }
      agent = described_class.new(
        name: "Test",
        instructions: instructions_proc
      )

      result = agent.get_system_prompt(context)
      expect(result).to eq("Dynamic: #{context}")
    end

    it "returns nil when no instructions provided" do
      agent = described_class.new(name: "Test")

      result = agent.get_system_prompt(context)
      expect(result).to be_nil
    end

    it "returns instructions without modification regardless of handoffs" do
      agent = described_class.new(
        name: "Test",
        instructions: "Base instructions"
      )
      agent.register_handoffs(other_agent)

      result = agent.get_system_prompt(context)
      expect(result).to eq("Base instructions")
    end

    it "returns instructions when no handoffs" do
      agent = described_class.new(
        name: "Test",
        instructions: "Base instructions"
      )

      result = agent.get_system_prompt(context)
      expect(result).to eq("Base instructions")
    end
  end
end
