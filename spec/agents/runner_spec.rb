# frozen_string_literal: true

require "spec_helper"
require "agents/runner"
require "agents/agent"
require "agents/context"
require "agents/handoff"
require "agents/items"

RSpec.describe Agents::Runner do
  # Test context class
  class TestContext < Agents::Context
    def initialize
      super
      @transitions = []
    end

    def record_agent_transition(from, to, reason)
      @transitions << { from: from, to: to, reason: reason }
    end

    attr_reader :transitions
  end

  # Test agents for testing handoffs
  class TestAgentA < Agents::Agent
    name "Test Agent A"
    instructions "Test agent A"

    def call(_input)
      # Simple response without handoff
      Agents::AgentResponse.new(content: "Response from Agent A")
    end
  end

  class TestAgentB < Agents::Agent
    name "Test Agent B"
    instructions "Test agent B"

    def call(_input)
      # Simple response without handoff
      Agents::AgentResponse.new(content: "Response from Agent B")
    end
  end

  class HandoffAgent < Agents::Agent
    name "Handoff Agent"
    instructions "Agent that always triggers a handoff"
    handoffs TestAgentB

    def call(_input)
      # Return response with handoff
      handoff_result = Agents::HandoffResult.new(
        target_agent_class: TestAgentB,
        reason: "Test handoff"
      )

      # Simulate tool call for handoff
      tool_calls = [{
        id: "call_123",
        name: "transfer_to_test_agent_b",
        arguments: {},
        result: {
          type: "handoff",
          target_class: TestAgentB,
          message: "Transferring to Test Agent B"
        }
      }]

      Agents::AgentResponse.new(
        content: "I'll transfer you to Agent B",
        handoff_result: handoff_result,
        tool_calls: tool_calls
      )
    end
  end

  # Forward declarations for circular references
  class LoopingAgentA < Agents::Agent; end
  class LoopingAgentB < Agents::Agent; end

  class LoopingAgentA < Agents::Agent
    name "Looping Agent A"
    instructions "Agent that hands off to B"
    handoffs LoopingAgentB

    def call(_input)
      handoff_result = Agents::HandoffResult.new(
        target_agent_class: LoopingAgentB,
        reason: "Loop test"
      )

      tool_calls = [{
        id: "call_loop_a",
        name: "transfer_to_looping_agent_b",
        arguments: {},
        result: {
          type: "handoff",
          target_class: LoopingAgentB,
          message: "Going to B"
        }
      }]

      Agents::AgentResponse.new(
        content: "Transferring to B",
        handoff_result: handoff_result,
        tool_calls: tool_calls
      )
    end
  end

  class LoopingAgentB < Agents::Agent
    name "Looping Agent B"
    instructions "Agent that hands off to A"
    handoffs LoopingAgentA

    def call(_input)
      handoff_result = Agents::HandoffResult.new(
        target_agent_class: LoopingAgentA,
        reason: "Loop test"
      )

      tool_calls = [{
        id: "call_loop_b",
        name: "transfer_to_looping_agent_a",
        arguments: {},
        result: {
          type: "handoff",
          target_class: LoopingAgentA,
          message: "Going to A"
        }
      }]

      Agents::AgentResponse.new(
        content: "Transferring to A",
        handoff_result: handoff_result,
        tool_calls: tool_calls
      )
    end
  end

  let(:context) { TestContext.new }
  let(:runner) { described_class.new(initial_agent: TestAgentA, context: context) }

  describe "#initialize" do
    it "sets the initial agent class and context" do
      expect(runner.context).to eq(context)
      expect(runner.run_items).to be_empty
      expect(runner.current_agent).to be_nil
    end
  end

  describe "#process" do
    context "with a simple agent" do
      it "processes a user message and returns agent response" do
        response = runner.process("Hello")

        expect(response).to eq("Response from Agent A")
        expect(runner.current_agent).to be_a(TestAgentA)
        expect(runner.run_items.size).to eq(2) # UserMessageItem + AssistantMessageItem

        # Check the items
        expect(runner.run_items[0]).to be_a(Agents::UserMessageItem)
        expect(runner.run_items[0].content).to eq("Hello")

        expect(runner.run_items[1]).to be_a(Agents::AssistantMessageItem)
        expect(runner.run_items[1].content).to eq("Response from Agent A")
        expect(runner.run_items[1].agent).to be_a(TestAgentA)
      end

      it "maintains conversation history across multiple messages" do
        runner.process("First message")
        runner.process("Second message")

        expect(runner.run_items.size).to eq(4) # 2 user + 2 assistant
        expect(runner.run_items[0].content).to eq("First message")
        expect(runner.run_items[2].content).to eq("Second message")
      end
    end

    context "with handoffs" do
      let(:runner) { described_class.new(initial_agent: HandoffAgent, context: context) }

      it "handles agent handoffs correctly" do
        response = runner.process("Hello")

        expect(response).to eq("Response from Agent B")
        expect(runner.current_agent).to be_a(TestAgentB)

        # Check run items: user message, tool call, handoff output, assistant message
        items = runner.run_items
        expect(items[0]).to be_a(Agents::UserMessageItem)
        expect(items[1]).to be_a(Agents::ToolCallItem)
        expect(items[1].tool_name).to eq("transfer_to_test_agent_b")
        expect(items[2]).to be_a(Agents::HandoffOutputItem)
        expect(items[3]).to be_a(Agents::AssistantMessageItem)
        expect(items[3].content).to eq("Response from Agent B")

        # Check context transitions
        expect(context.transitions.size).to eq(1)
        expect(context.transitions[0]).to eq({
                                               from: "Handoff Agent",
                                               to: "Test Agent B",
                                               reason: "Test handoff"
                                             })
      end

      it "does not add content when there are tool calls" do
        runner.process("Hello")

        # The handoff agent's content "I'll transfer you to Agent B" should NOT appear
        assistant_messages = runner.run_items.select { |item| item.is_a?(Agents::AssistantMessageItem) }
        expect(assistant_messages.size).to eq(1)
        expect(assistant_messages[0].content).to eq("Response from Agent B")
        expect(assistant_messages[0].agent).to be_a(TestAgentB)
      end
    end

    context "with infinite loop protection" do
      let(:runner) { described_class.new(initial_agent: LoopingAgentA, context: context) }

      it "raises an error when maximum handoffs are exceeded" do
        expect do
          runner.process("Start loop")
        end.to raise_error(RuntimeError, /Maximum handoffs .* exceeded/)
      end
    end
  end

  describe "#conversation_summary" do
    it "formats the conversation history" do
      runner.process("Hello")
      summary = runner.conversation_summary

      expect(summary).to include("[User]: Hello")
      expect(summary).to include("[Test Agent A]: Response from Agent A")
    end

    context "with handoffs" do
      let(:runner) { described_class.new(initial_agent: HandoffAgent, context: context) }

      it "includes tool calls and handoffs in summary" do
        runner.process("Hello")
        summary = runner.conversation_summary

        expect(summary).to include("[User]: Hello")
        expect(summary).to include("[Handoff Agent]: Called tool 'transfer_to_test_agent_b'")
        expect(summary).to include("[System]: Handoff from Handoff Agent to TestAgentB")
        expect(summary).to include("[Test Agent B]: Response from Agent B")
      end
    end
  end

  describe "private methods" do
    describe "#build_agent_input" do
      it "filters out nil items from handoff outputs" do
        # Add a handoff output item
        handoff_output = Agents::HandoffOutputItem.new(
          tool_call_id: "call_123",
          output: "Transferring",
          source_agent: TestAgentA.new(context: context),
          target_agent: TestAgentB,
          agent: TestAgentA.new(context: context)
        )

        runner.instance_variable_set(:@run_items, [
                                       Agents::UserMessageItem.new(content: "Hello", agent: nil),
                                       handoff_output
                                     ])

        # HandoffOutputItem.to_input_item returns nil, so it should be filtered
        input = runner.send(:build_agent_input)
        expect(input.size).to eq(1)
        expect(input[0][:role]).to eq("user")
        expect(input[0][:content]).to eq("Hello")
      end
    end
  end
end
