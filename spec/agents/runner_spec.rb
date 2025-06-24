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

      # Mock the agent's call method
      allow_any_instance_of(TestAgentB).to receive(:call).and_return(
        Agents::AgentResponse.new(content: "Response from Agent B")
      )

      runner.process("Hello")
      expect(runner.current_agent).to be_a(TestAgentB)
    end

    it "requires context to be provided" do
      expect do
        described_class.new(initial_agent: TestAgentA)
      end.to raise_error(ArgumentError, /missing keyword: :context/)
    end
  end

  describe "#process" do
    it "executes the initial agent" do
      # Mock the agent's call method
      allow_any_instance_of(TestAgentA).to receive(:call).and_return(
        Agents::AgentResponse.new(content: "Response from Agent A")
      )

      result = runner.process("Hello")

      expect(result).to eq("Response from Agent A")
      expect(runner.run_items.size).to eq(2) # UserMessageItem + AssistantMessageItem
      expect(runner.current_agent).to be_a(TestAgentA)
    end

    it "handles handoffs between agents" do
      runner = described_class.new(initial_agent: HandoffAgent, context: context)

      # Mock handoff agent to trigger handoff
      handoff_result = Agents::HandoffResult.new(
        target_agent_class: TestAgentB,
        reason: "Test handoff"
      )

      tool_calls = [{
        id: "call_123",
        name: "transfer_to_test_agent_b",
        arguments: {},
        result: { type: "handoff", target_class: TestAgentB, message: "Transferring to Test Agent B" }
      }]

      allow_any_instance_of(HandoffAgent).to receive(:call).and_return(
        Agents::AgentResponse.new(
          content: nil,
          handoff_result: handoff_result,
          tool_calls: tool_calls
        )
      )

      # Mock target agent response
      allow_any_instance_of(TestAgentB).to receive(:call).and_return(
        Agents::AgentResponse.new(content: "Response from Agent B")
      )

      result = runner.process("Please handoff")

      expect(result).to eq("Response from Agent B")
      expect(runner.current_agent).to be_a(TestAgentB)
    end

    it "prevents infinite handoff loops" do
      runner = described_class.new(initial_agent: LoopingAgentA, context: context)

      # Mock both agents to create a loop
      handoff_to_b = Agents::HandoffResult.new(
        target_agent_class: LoopingAgentB,
        reason: "Loop test"
      )

      handoff_to_a = Agents::HandoffResult.new(
        target_agent_class: LoopingAgentA,
        reason: "Loop test"
      )

      allow_any_instance_of(LoopingAgentA).to receive(:call).and_return(
        Agents::AgentResponse.new(
          content: nil,
          handoff_result: handoff_to_b,
          tool_calls: [{
            id: "call_a",
            name: "transfer",
            result: { type: "handoff", target_class: LoopingAgentB, message: "To B" }
          }]
        )
      )

      allow_any_instance_of(LoopingAgentB).to receive(:call).and_return(
        Agents::AgentResponse.new(
          content: nil,
          handoff_result: handoff_to_a,
          tool_calls: [{
            id: "call_b",
            name: "transfer",
            result: { type: "handoff", target_class: LoopingAgentA, message: "To A" }
          }]
        )
      )

      expect do
        runner.process("Start looping")
      end.to raise_error(RuntimeError, /Maximum handoffs \(10\) exceeded/)
    end

    it "tracks conversation context through handoffs" do
      runner = described_class.new(initial_agent: HandoffAgent, context: context)

      # Set some context before running
      context[:user_id] = "123"
      context[:session] = "test-session"

      # Mock handoff
      handoff_result = Agents::HandoffResult.new(
        target_agent_class: TestAgentB,
        reason: "Test handoff"
      )

      allow_any_instance_of(HandoffAgent).to receive(:call).and_return(
        Agents::AgentResponse.new(
          content: nil,
          handoff_result: handoff_result,
          tool_calls: [{
            id: "call_123",
            name: "transfer_to_test_agent_b",
            result: { type: "handoff", target_class: TestAgentB, message: "Transferring" }
          }]
        )
      )

      allow_any_instance_of(TestAgentB).to receive(:call).and_return(
        Agents::AgentResponse.new(content: "Done")
      )

      runner.process("Transfer me")

      # Context should be preserved
      expect(context[:user_id]).to eq("123")
      expect(context[:session]).to eq("test-session")
    end

    it "records transitions in context if supported" do
      runner = described_class.new(initial_agent: HandoffAgent, context: context)

      # Mock handoff
      handoff_result = Agents::HandoffResult.new(
        target_agent_class: TestAgentB,
        reason: "Test handoff"
      )

      allow_any_instance_of(HandoffAgent).to receive(:call).and_return(
        Agents::AgentResponse.new(
          content: nil,
          handoff_result: handoff_result,
          tool_calls: [{
            id: "call_123",
            name: "transfer_to_test_agent_b",
            result: { type: "handoff", target_class: TestAgentB, message: "Transferring" }
          }]
        )
      )

      allow_any_instance_of(TestAgentB).to receive(:call).and_return(
        Agents::AgentResponse.new(content: "Done")
      )

      runner.process("Transfer me")

      expect(context.transitions).to eq([{
                                          from: "Handoff Agent",
                                          to: "Test Agent B",
                                          reason: "Test handoff"
                                        }])
    end
  end

  describe "#run_items" do
    it "tracks all items during execution" do
      allow_any_instance_of(TestAgentA).to receive(:call).and_return(
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
      allow_any_instance_of(TestAgentA).to receive(:call).and_return(
        Agents::AgentResponse.new(content: "Response")
      )

      runner.process("Hello")
      expect(runner.current_agent).to be_a(TestAgentA)
    end

    it "returns the final agent after handoffs" do
      runner = described_class.new(initial_agent: HandoffAgent, context: context)

      # Mock handoff
      handoff_result = Agents::HandoffResult.new(
        target_agent_class: TestAgentB,
        reason: "Test handoff"
      )

      allow_any_instance_of(HandoffAgent).to receive(:call).and_return(
        Agents::AgentResponse.new(
          content: nil,
          handoff_result: handoff_result,
          tool_calls: [{
            id: "call_123",
            name: "transfer_to_test_agent_b",
            result: { type: "handoff", target_class: TestAgentB, message: "Transferring" }
          }]
        )
      )

      allow_any_instance_of(TestAgentB).to receive(:call).and_return(
        Agents::AgentResponse.new(content: "Done")
      )

      runner.process("Transfer me")
      expect(runner.current_agent).to be_a(TestAgentB)
    end
  end

  describe "#conversation_summary" do
    it "returns formatted summary of the conversation" do
      allow_any_instance_of(TestAgentA).to receive(:call).and_return(
        Agents::AgentResponse.new(content: "Response from A")
      )

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
    it "accumulates run items across multiple runs" do
      allow_any_instance_of(TestAgentA).to receive(:call).and_return(
        Agents::AgentResponse.new(content: "Response from Agent A")
      )

      runner.process("First message")
      runner.process("Second message")

      expect(runner.run_items.size).to eq(4) # 2 user messages + 2 assistant messages
    end

    it "maintains agent instance across runs" do
      allow_any_instance_of(TestAgentA).to receive(:call).and_return(
        Agents::AgentResponse.new(content: "Response")
      )

      runner.process("Hello")
      first_agent = runner.current_agent

      runner.process("Hello again")
      second_agent = runner.current_agent

      # Should be the same agent instance
      expect(first_agent).to eq(second_agent)
    end
  end
end
