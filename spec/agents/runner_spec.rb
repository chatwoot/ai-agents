# frozen_string_literal: true

require "spec_helper"
require "agents/runner"
require "agents/agent"
require "agents/context"
require "agents/handoff"
require "agents/items"
require "ruby_llm"

RSpec.describe Agents::Runner do
  # Test context class
  let(:test_context_class) do
    Class.new(Agents::Context) do
      def initialize
        super
        @transitions = []
      end

      def record_agent_transition(from, to, reason)
        @transitions << { from: from, to: to, reason: reason }
      end

      attr_reader :transitions
    end
  end
  let(:context) { TestContext.new }
  let(:runner) { described_class.new(initial_agent: TestAgentA, context: context) }

  # Mock RubyLLM chat for testing
  let(:mock_chat) { instance_double(RubyLLM::Chat) }

  # Test agents for testing handoffs
  let(:test_agent_a_class) do
    Class.new(Agents::Agent) do
      name "Test Agent A"
      instructions "Test agent A"
    end
  end

  let(:test_agent_b_class) do
    Class.new(Agents::Agent) do
      name "Test Agent B"
      instructions "Test agent B"
    end
  end

  let(:handoff_agent_class) do
    agent_b = test_agent_b_class
    Class.new(Agents::Agent) do
      name "Handoff Agent"
      instructions "Agent that always triggers a handoff"
      handoffs agent_b
    end
  end

  # Create looping agents with circular references
  let(:looping_agents) do
    # We need to create both classes with a reference to each other
    agent_a = nil

    agent_b = Class.new(Agents::Agent) do
      name "Looping Agent B"
      instructions "Agent that hands off to A"

      define_singleton_method :handoff_target do
        agent_a
      end
    end

    agent_a = Class.new(Agents::Agent) do
      name "Looping Agent A"
      instructions "Agent that hands off to B"
      handoffs agent_b
    end

    # Now update agent_b with the handoff to agent_a
    agent_b.handoffs agent_a

    { agent_a: agent_a, agent_b: agent_b }
  end

  before do
    stub_const("TestContext", test_context_class)
    stub_const("TestAgentA", test_agent_a_class)
    stub_const("TestAgentB", test_agent_b_class)
    stub_const("HandoffAgent", handoff_agent_class)
    stub_const("LoopingAgentA", looping_agents[:agent_a])
    stub_const("LoopingAgentB", looping_agents[:agent_b])
  end

  describe "#initialize" do
    it "sets the initial agent class and context" do
      expect(runner.context).to eq(context)
      expect(runner.run_items).to be_empty
      expect(runner.current_agent).to be_nil
    end

    it "allows starting with a different agent" do
      runner = described_class.new(initial_agent: TestAgentB, context: context)

      # Create agent instance and mock its call method
      agent_b = instance_double(TestAgentB)
      allow(TestAgentB).to receive(:new).with(context: context).and_return(agent_b)
      allow(agent_b).to receive(:call).and_return(
        Agents::AgentResponse.new(content: "Response from Agent B")
      )

      runner.process("Hello")
      expect(runner.current_agent).to eq(agent_b)
    end

    it "requires context to be provided" do
      expect do
        described_class.new(initial_agent: TestAgentA)
      end.to raise_error(ArgumentError, /missing keyword: :context/)
    end
  end

  describe "#process" do
    it "executes the initial agent" do
      # Create agent instance and mock its call method
      agent_a = instance_double(TestAgentA)
      allow(TestAgentA).to receive(:new).with(context: context).and_return(agent_a)
      allow(agent_a).to receive(:call).and_return(
        Agents::AgentResponse.new(content: "Response from Agent A")
      )

      result = runner.process("Hello")

      expect(result).to eq("Response from Agent A")
      expect(runner.run_items.size).to eq(2) # UserMessageItem + AssistantMessageItem
      expect(runner.current_agent).to eq(agent_a)
    end

    context "when handling handoffs" do
      let(:handoff_runner) { described_class.new(initial_agent: HandoffAgent, context: context) }
      let(:handoff_agent) { instance_double(HandoffAgent) }
      let(:agent_b) { instance_double(TestAgentB) }
      let(:handoff_result) do
        Agents::HandoffResult.new(
          target_agent_class: TestAgentB,
          reason: "Test handoff"
        )
      end

      before do
        allow(HandoffAgent).to receive(:new).with(context: context).and_return(handoff_agent)
        allow(TestAgentB).to receive(:new).with(context: context).and_return(agent_b)

        allow(handoff_agent).to receive(:call).and_return(
          Agents::AgentResponse.new(
            content: nil,
            handoff_result: handoff_result,
            tool_calls: [{
              id: "call_123",
              name: "transfer_to_test_agent_b",
              arguments: {}
            }]
          )
        )

        allow(agent_b).to receive(:call).and_return(
          Agents::AgentResponse.new(content: "Response from Agent B")
        )
      end

      it "processes handoffs between agents" do
        result = handoff_runner.process("Please handoff")
        expect(result).to eq("Response from Agent B")
      end

      it "updates current agent after handoff" do
        handoff_runner.process("Please handoff")
        expect(handoff_runner.current_agent).to eq(agent_b)
      end
    end

    context "when agents create infinite loops" do
      let(:loop_runner) { described_class.new(initial_agent: LoopingAgentA, context: context) }
      let(:looping_agent_a) { instance_double(LoopingAgentA) }
      let(:looping_agent_b) { instance_double(LoopingAgentB) }

      before do
        # Set up circular mocking
        allow(LoopingAgentA).to receive(:new).with(context: context).and_return(looping_agent_a)
        allow(LoopingAgentB).to receive(:new).with(context: context).and_return(looping_agent_b)

        # Agent A always hands off to B
        allow(looping_agent_a).to receive(:call).and_return(
          Agents::AgentResponse.new(
            content: nil,
            handoff_result: Agents::HandoffResult.new(
              target_agent_class: LoopingAgentB,
              reason: "Loop test"
            ),
            tool_calls: [{
              id: "call_a",
              name: "transfer",
              arguments: {}
            }]
          )
        )

        # Agent B always hands off to A
        allow(looping_agent_b).to receive(:call).and_return(
          Agents::AgentResponse.new(
            content: nil,
            handoff_result: Agents::HandoffResult.new(
              target_agent_class: LoopingAgentA,
              reason: "Loop test"
            ),
            tool_calls: [{
              id: "call_b",
              name: "transfer",
              arguments: {}
            }]
          )
        )
      end

      it "prevents infinite handoff loops" do
        expect do
          loop_runner.process("Start looping")
        end.to raise_error(RuntimeError, /Maximum handoffs \(10\) exceeded/)
      end
    end

    context "when tracking context through handoffs" do
      let(:context_runner) { described_class.new(initial_agent: HandoffAgent, context: context) }
      let(:handoff_agent) { instance_double(HandoffAgent) }
      let(:agent_b) { instance_double(TestAgentB) }

      before do
        context[:user_id] = "123"
        context[:session] = "test-session"

        allow(HandoffAgent).to receive(:new).with(context: context).and_return(handoff_agent)
        allow(TestAgentB).to receive(:new).with(context: context).and_return(agent_b)

        allow(handoff_agent).to receive(:call).and_return(
          Agents::AgentResponse.new(
            content: nil,
            handoff_result: Agents::HandoffResult.new(
              target_agent_class: TestAgentB,
              reason: "Test handoff"
            ),
            tool_calls: [{
              id: "call_123",
              name: "transfer_to_test_agent_b",
              arguments: {}
            }]
          )
        )

        allow(agent_b).to receive(:call).and_return(
          Agents::AgentResponse.new(content: "Done")
        )
      end

      it "preserves context through handoffs" do
        context_runner.process("Transfer me")
        expect(context[:user_id]).to eq("123")
        expect(context[:session]).to eq("test-session")
      end
    end

    context "when recording transitions" do
      let(:transition_runner) { described_class.new(initial_agent: HandoffAgent, context: context) }
      let(:handoff_agent) { instance_double(HandoffAgent) }
      let(:agent_b) { instance_double(TestAgentB) }

      before do
        allow(HandoffAgent).to receive(:new).with(context: context).and_return(handoff_agent)
        allow(TestAgentB).to receive(:new).with(context: context).and_return(agent_b)

        # Mock the class method to return the correct name

        allow(handoff_agent).to receive_messages(class: HandoffAgent, call: Agents::AgentResponse.new(
          content: nil,
          handoff_result: Agents::HandoffResult.new(
            target_agent_class: TestAgentB,
            reason: "Test handoff"
          ),
          tool_calls: [{
            id: "call_123",
            name: "transfer_to_test_agent_b",
            arguments: {}
          }]
        ))

        allow(agent_b).to receive_messages(class: TestAgentB, call: Agents::AgentResponse.new(content: "Done"))
      end

      it "records transitions in context" do
        transition_runner.process("Transfer me")
        expect(context.transitions).to eq([{
                                            from: "Handoff Agent",
                                            to: "Test Agent B",
                                            reason: "Test handoff"
                                          }])
      end
    end
  end

  describe "#run_items" do
    it "tracks all items during execution" do
      agent_a = instance_double(TestAgentA)
      allow(TestAgentA).to receive(:new).with(context: context).and_return(agent_a)
      allow(agent_a).to receive(:call).and_return(
        Agents::AgentResponse.new(content: "Response")
      )

      runner.process("Hello")
      items = runner.run_items

      expect(items.size).to eq(2)
      expect(items[0]).to be_a(Agents::UserMessageItem)
      expect(items[1]).to be_a(Agents::AssistantMessageItem)
    end
  end

  describe "#current_agent" do
    it "returns nil before running" do
      expect(runner.current_agent).to be_nil
    end

    it "returns the last active agent after running" do
      agent_a = instance_double(TestAgentA)
      allow(TestAgentA).to receive(:new).with(context: context).and_return(agent_a)
      allow(agent_a).to receive(:call).and_return(
        Agents::AgentResponse.new(content: "Response")
      )

      runner.process("Hello")
      expect(runner.current_agent).to eq(agent_a)
    end

    context "when handoffs are done" do
      let(:handoff_runner) { described_class.new(initial_agent: HandoffAgent, context: context) }
      let(:handoff_agent) { instance_double(HandoffAgent) }
      let(:agent_b) { instance_double(TestAgentB) }

      before do
        allow(HandoffAgent).to receive(:new).with(context: context).and_return(handoff_agent)
        allow(TestAgentB).to receive(:new).with(context: context).and_return(agent_b)

        allow(handoff_agent).to receive(:call).and_return(
          Agents::AgentResponse.new(
            content: nil,
            handoff_result: Agents::HandoffResult.new(
              target_agent_class: TestAgentB,
              reason: "Test handoff"
            ),
            tool_calls: [{
              id: "call_123",
              name: "transfer_to_test_agent_b",
              arguments: {}
            }]
          )
        )

        allow(agent_b).to receive(:call).and_return(
          Agents::AgentResponse.new(content: "Done")
        )
      end

      it "returns the final agent after handoffs" do
        handoff_runner.process("Transfer me")
        expect(handoff_runner.current_agent).to eq(agent_b)
      end
    end
  end

  describe "#conversation_summary" do
    it "returns formatted summary of the conversation" do
      agent_a = instance_double(TestAgentA)
      allow(TestAgentA).to receive(:new).with(context: context).and_return(agent_a)
      allow(agent_a).to receive_messages(call: Agents::AgentResponse.new(content: "Response from A"), class: TestAgentA)

      runner.process("Hello")
      summary = runner.conversation_summary

      expect(summary).to include("[User]: Hello")
      expect(summary).to include("[Test Agent A]: Response from A")
    end
  end

  describe "error handling" do
    let(:error_agent_class) do
      Class.new(Agents::Agent) do
        name "Error Agent"

        def call(_input)
          raise StandardError, "Agent error"
        end
      end
    end

    before do
      stub_const("ErrorAgent", error_agent_class)
    end

    it "captures and re-raises agent errors" do
      runner = described_class.new(initial_agent: ErrorAgent, context: context)

      expect do
        runner.process("Hello")
      end.to raise_error(StandardError, "Agent error")
    end

    it "propagates agent errors" do
      runner = described_class.new(initial_agent: ErrorAgent, context: context)

      begin
        runner.process("Hello")
      rescue StandardError
        # Expected
      end

      # User message item should still be recorded
      expect(runner.run_items.size).to eq(1)
      expect(runner.run_items.first).to be_a(Agents::UserMessageItem)
    end
  end

  describe "multiple runs" do
    let(:agent_a) { instance_double(TestAgentA) }

    before do
      allow(TestAgentA).to receive(:new).with(context: context).and_return(agent_a)
      allow(agent_a).to receive(:call).and_return(
        Agents::AgentResponse.new(content: "Response from Agent A")
      )
    end

    it "accumulates run items across multiple runs" do
      runner.process("First message")
      runner.process("Second message")

      expect(runner.run_items.size).to eq(4) # 2 user messages + 2 assistant messages
    end

    it "maintains agent instance across runs" do
      runner.process("Hello")
      first_agent = runner.current_agent

      runner.process("Hello again")
      second_agent = runner.current_agent

      # Should be the same agent instance
      expect(first_agent).to eq(second_agent)
    end
  end
end
