# frozen_string_literal: true

require "spec_helper"
require "agents/agent"
require "agents/tool"
require "agents/context"
require "agents/handoff"

RSpec.describe Agents::Agent do
  # Test tool
  class TestTool < Agents::Tool
    description "A test tool"
    param :input, String, "Test input"

    def perform(input:, context:)
      "Tool executed: #{input}"
    end
  end

  # Another test tool
  class AnotherTool < Agents::Tool
    description "Another test tool"

    def perform(context:)
      "Another tool executed"
    end
  end

  # Test agent
  class TestAgent < described_class
    name "Test Agent"
    instructions "Test instructions"
    provider :openai
    model "gpt-4"
    uses TestTool
  end

  # Agent with dynamic instructions
  class DynamicAgent < described_class
    name "Dynamic Agent"
    instructions ->(context) { "Instructions for #{context[:user]}" }
  end

  # Forward declarations for handoffs
  class HandoffSourceAgent < described_class; end
  class HandoffTargetAgent < described_class; end

  # Agent with handoffs
  class HandoffSourceAgent < described_class
    name "Handoff Source"
    instructions "Source agent"
    handoffs HandoffTargetAgent
  end

  class HandoffTargetAgent < described_class
    name "Handoff Target"
    instructions "Target agent"
  end

  # Agent with multiple tools
  class MultiToolAgent < described_class
    name "Multi Tool Agent"
    uses TestTool
    uses AnotherTool
  end

  describe "class methods" do
    describe ".name" do
      it "returns the configured name" do
        expect(TestAgent.name).to eq("Test Agent")
      end

      it "generates a default name from class name" do
        class UnnamedAgent < described_class; end
        expect(UnnamedAgent.name).to eq("Unnamed")
      end

      it "removes Agent suffix from generated names" do
        class CustomerServiceAgent < described_class; end
        expect(CustomerServiceAgent.name).to eq("CustomerService")
      end
    end

    describe ".instructions" do
      it "returns configured instructions" do
        expect(TestAgent.instructions).to eq("Test instructions")
      end

      it "returns default instructions if not configured" do
        class NoInstructionsAgent < described_class; end
        expect(NoInstructionsAgent.instructions).to eq("You are a helpful AI assistant.")
      end

      it "can be a proc" do
        expect(DynamicAgent.instructions).to be_a(Proc)
      end
    end

    describe ".provider" do
      it "returns configured provider" do
        expect(TestAgent.provider).to eq(:openai)
      end

      it "returns default provider if not configured" do
        class NoProviderAgent < described_class; end
        expect(NoProviderAgent.provider).to eq(Agents.configuration.default_provider)
      end
    end

    describe ".model" do
      it "returns configured model" do
        expect(TestAgent.model).to eq("gpt-4")
      end

      it "returns default model if not configured" do
        class NoModelAgent < described_class; end
        expect(NoModelAgent.model).to eq(Agents.configuration.default_model)
      end
    end

    describe ".uses" do
      it "registers tools" do
        expect(TestAgent.tools).to include(TestTool)
      end

      it "prevents duplicate tool registration" do
        TestAgent.uses(TestTool) # Try to add again
        expect(TestAgent.tools.count(TestTool)).to eq(1)
      end

      it "can register multiple tools" do
        expect(MultiToolAgent.tools).to include(TestTool, AnotherTool)
      end
    end

    describe ".handoffs" do
      it "registers handoff targets" do
        expect(HandoffSourceAgent.handoffs).to eq([HandoffTargetAgent])
      end

      it "returns empty array when no handoffs configured" do
        expect(TestAgent.handoffs).to eq([])
      end
    end

    describe ".call" do
      it "creates an instance and calls it" do
        mock_response = double("response", content: "Test response", tool_calls: nil)
        mock_chat = double("chat")
        allow(mock_chat).to receive_messages(with_instructions: mock_chat, with_tool: mock_chat, ask: mock_response)
        allow(RubyLLM).to receive(:chat).and_return(mock_chat)

        response = TestAgent.call("Hello")
        expect(response).to be_a(Agents::AgentResponse)
        expect(response.content).to eq("Test response")
      end
    end

    describe ".to_proc" do
      it "returns a proc that calls the agent" do
        mock_response = double("response", content: "Test response", tool_calls: nil)
        mock_chat = double("chat")
        allow(mock_chat).to receive_messages(with_instructions: mock_chat, with_tool: mock_chat, ask: mock_response)
        allow(RubyLLM).to receive(:chat).and_return(mock_chat)

        proc = TestAgent.to_proc
        response = proc.call("Hello")
        expect(response).to be_a(Agents::AgentResponse)
      end
    end
  end

  describe "instance methods" do
    let(:agent) { TestAgent.new }
    let(:context) { Agents::Context.new(user: "test_user") }
    let(:agent_with_context) { TestAgent.new(context: context) }

    describe "#initialize" do
      it "accepts a hash context" do
        agent = TestAgent.new(context: { key: "value" })
        expect(agent.instance_variable_get(:@context)).to be_a(Agents::Context)
      end

      it "accepts an Agents::Context" do
        agent = TestAgent.new(context: context)
        expect(agent.instance_variable_get(:@context)).to eq(context)
      end
    end

    describe "#call" do
      let(:mock_response) { double("response", content: "Test response", tool_calls: nil) }
      let(:mock_chat) { double("chat") }

      before do
        allow(mock_chat).to receive(:add_message)
        allow(mock_chat).to receive_messages(with_instructions: mock_chat, with_tool: mock_chat, ask: mock_response,
                                             complete: mock_response)
        allow(RubyLLM).to receive(:chat).and_return(mock_chat)
      end

      context "with string input" do
        it "processes simple string input" do
          response = agent.call("Hello")

          expect(response).to be_a(Agents::AgentResponse)
          expect(response.content).to eq("Test response")
          expect(response.handoff_result).to be_nil
        end

        it "passes input to chat.ask" do
          expect(mock_chat).to receive(:ask).with("Hello").and_return(mock_response)
          agent.call("Hello")
        end
      end

      context "with array input (prepared conversation)" do
        it "restores conversation history" do
          input = [
            { role: "user", content: "First message" },
            { role: "assistant", content: "First response" },
            { role: "user", content: "Second message" }
          ]

          expect(mock_chat).to receive(:add_message).with(role: :user, content: "First message")
          expect(mock_chat).to receive(:add_message).with(role: :assistant, content: "First response")
          expect(mock_chat).to receive(:add_message).with(role: :user, content: "Second message")
          expect(mock_chat).to receive(:complete).and_return(mock_response)

          response = agent.call(input)
          expect(response.content).to eq("Test response")
        end

        it "handles tool calls in conversation history" do
          tool_calls = [{ id: "call_123", name: "test_tool", arguments: { input: "test" } }]
          input = [
            { role: "user", content: "Use the tool" },
            { role: "assistant", tool_calls: tool_calls },
            { role: "tool", tool_call_id: "call_123", content: "Tool result" }
          ]

          expect(mock_chat).to receive(:add_message).with(role: :user, content: "Use the tool")
          expect(mock_chat).to receive(:add_message).with(role: :assistant, tool_calls: tool_calls)
          expect(mock_chat).to receive(:add_message).with(role: :tool, tool_call_id: "call_123", content: "Tool result")

          agent.call(input)
        end
      end

      context "with dynamic instructions" do
        it "resolves proc instructions with context" do
          agent = DynamicAgent.new(context: { user: "Alice" })

          expect(mock_chat).to receive(:with_instructions).with("Instructions for Alice")
          agent.call("Hello")
        end
      end

      context "with tools" do
        it "instantiates and adds tools to chat" do
          expect_any_instance_of(TestTool).to receive(:set_context).with(anything)
          expect(mock_chat).to receive(:with_tool).with(instance_of(TestTool))

          agent.call("Hello")
        end
      end

      context "with handoffs" do
        let(:source_agent) { HandoffSourceAgent.new(context: context) }

        it "creates handoff tools automatically" do
          expect(mock_chat).to receive(:with_tool).with(instance_of(Agents::HandoffTool))
          source_agent.call("Hello")
        end

        it "detects handoffs from context" do
          # Directly set the pending handoff in context as if a tool had set it
          # The agent checks for this after processing the response
          allow(source_agent).to receive(:detect_handoff_from_context).and_return(
            Agents::HandoffResult.new(
              target_agent_class: HandoffTargetAgent,
              reason: "Test handoff"
            )
          )

          response = source_agent.call("Hello")
          expect(response.handoff_result).to be_a(Agents::HandoffResult)
          expect(response.handoff_result.target_agent_class).to eq(HandoffTargetAgent)
          expect(response.handoff_result.reason).to eq("Test handoff")
        end
      end

      context "with tool calls in response" do
        let(:tool_call) do
          double("tool_call",
                 id: "call_123",
                 name: "test_tool",
                 arguments: { input: "test" },
                 result: "Tool result")
        end
        let(:mock_response_with_tools) do
          double("response", content: "Using tool", tool_calls: [tool_call])
        end

        it "extracts tool calls from response" do
          allow(mock_chat).to receive(:ask).and_return(mock_response_with_tools)

          response = agent.call("Hello")
          expect(response.tool_calls).to be_an(Array)
          expect(response.tool_calls.size).to eq(1)
          expect(response.tool_calls[0][:name]).to eq("test_tool")
          expect(response.tool_calls[0][:result]).to eq("Tool result")
        end
      end

      context "error handling" do
        it "handles RubyLLM errors" do
          # Create a mock response with a body method for RubyLLM::Error
          mock_error_response = double("error_response", body: "LLM failed")
          llm_error = RubyLLM::Error.new(mock_error_response)
          allow(mock_chat).to receive(:ask).and_raise(llm_error)

          expect { agent.call("Hello") }.to raise_error(
            Agents::Agent::ExecutionError,
            "LLM error: LLM failed"
          )
        end

        it "handles general errors" do
          allow(mock_chat).to receive(:ask).and_raise(StandardError, "Something went wrong")

          expect { agent.call("Hello") }.to raise_error(
            Agents::Agent::ExecutionError,
            "Agent execution failed: Something went wrong"
          )
        end
      end
    end

    describe "#metadata" do
      it "returns agent metadata" do
        metadata = agent.metadata

        expect(metadata[:name]).to eq("Test Agent")
        expect(metadata[:instructions]).to eq("Test instructions")
        expect(metadata[:provider]).to eq(:openai)
        expect(metadata[:model]).to eq("gpt-4")
        expect(metadata[:tools]).to eq([TestTool.name])
      end
    end

    describe "#[]" do
      it "is an alias for call" do
        mock_response = double("response", content: "Test response", tool_calls: nil)
        mock_chat = double("chat")
        allow(mock_chat).to receive_messages(with_instructions: mock_chat, with_tool: mock_chat, ask: mock_response)
        allow(RubyLLM).to receive(:chat).and_return(mock_chat)

        response = agent["Hello"]
        expect(response).to be_a(Agents::AgentResponse)
      end
    end
  end

  # Test guardrails after main tests
end
