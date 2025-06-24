# frozen_string_literal: true

require "spec_helper"
require "agents/agent"
require "agents/tool"
require "agents/context"
require "agents/handoff"

RSpec.describe Agents::Agent do
  let(:test_tool_class) do
    Class.new(Agents::Tool) do
      description "A test tool"
      param :input, String, "Test input"

      def perform(input:, context:)
        _ = context # Mark as used
        "Tool executed: #{input}"
      end
    end
  end

  let(:another_tool_class) do
    Class.new(Agents::Tool) do
      description "Another test tool"

      def perform(context:)
        _ = context # Mark as used
        "Another tool executed"
      end
    end
  end

  let(:test_agent_class) do
    tool_class = test_tool_class
    Class.new(described_class) do
      name "Test Agent"
      instructions "Test instructions"
      provider :openai
      model "gpt-4"
      uses tool_class
    end
  end

  let(:dynamic_agent_class) do
    Class.new(described_class) do
      name "Dynamic Agent"
      instructions ->(context) { "Instructions for #{context[:user]}" }
    end
  end

  let(:handoff_target_agent_class) do
    Class.new(described_class) do
      name "Handoff Target"
      instructions "Target agent"
    end
  end

  let(:handoff_source_agent_class) do
    target_class = handoff_target_agent_class
    Class.new(described_class) do
      name "Handoff Source"
      instructions "Source agent"
      handoffs target_class
    end
  end

  let(:multi_tool_agent_class) do
    tool1 = test_tool_class
    tool2 = another_tool_class
    Class.new(described_class) do
      name "Multi Tool Agent"
      uses tool1
      uses tool2
    end
  end

  before do
    stub_const("TestTool", test_tool_class)
    stub_const("AnotherTool", another_tool_class)
    stub_const("TestAgent", test_agent_class)
    stub_const("DynamicAgent", dynamic_agent_class)
    stub_const("HandoffTargetAgent", handoff_target_agent_class)
    stub_const("HandoffSourceAgent", handoff_source_agent_class)
    stub_const("MultiToolAgent", multi_tool_agent_class)
  end

  describe "class methods" do
    describe ".name" do
      it "returns the configured name" do
        expect(TestAgent.name).to eq("Test Agent")
      end

      it "generates a default name from class name" do
        unnamed_agent = Class.new(described_class)
        stub_const("UnnamedAgent", unnamed_agent)
        expect(UnnamedAgent.name).to eq("Unnamed")
      end

      it "removes Agent suffix from generated names" do
        customer_service_agent = Class.new(described_class)
        stub_const("CustomerServiceAgent", customer_service_agent)
        expect(CustomerServiceAgent.name).to eq("CustomerService")
      end
    end

    describe ".instructions" do
      it "returns configured instructions" do
        expect(TestAgent.instructions).to eq("Test instructions")
      end

      it "returns default instructions if not configured" do
        no_instructions_agent = Class.new(described_class)
        stub_const("NoInstructionsAgent", no_instructions_agent)
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

      it "returns configured provider from Agents module if not set" do
        no_provider_agent = Class.new(described_class)
        stub_const("NoProviderAgent", no_provider_agent)
        allow(Agents.configuration).to receive(:default_provider).and_return(:anthropic)
        expect(NoProviderAgent.provider).to eq(:anthropic)
      end
    end

    describe ".model" do
      it "returns configured model" do
        expect(TestAgent.model).to eq("gpt-4")
      end

      it "returns configured model from Agents module if not set" do
        no_model_agent = Class.new(described_class)
        stub_const("NoModelAgent", no_model_agent)
        allow(Agents.configuration).to receive(:default_model).and_return("claude-3")
        expect(NoModelAgent.model).to eq("claude-3")
      end
    end

    describe ".uses" do
      it "registers a single tool" do
        expect(TestAgent.tools).to eq([TestTool])
      end

      it "registers multiple tools" do
        expect(MultiToolAgent.tools).to eq([TestTool, AnotherTool])
      end

      it "returns empty array when no tools registered" do
        expect(DynamicAgent.tools).to eq([])
      end
    end

    describe ".handoffs" do
      it "registers handoff targets" do
        expect(HandoffSourceAgent.handoffs).to eq([HandoffTargetAgent])
      end

      it "returns empty array when no handoffs registered" do
        expect(TestAgent.handoffs).to eq([])
      end
    end
  end

  describe "instance methods" do
    let(:context) { Agents::Context.new }
    let(:agent) { TestAgent.new(context: context) }

    describe "#initialize" do
      it "initializes with context" do
        expect(agent.instance_variable_get(:@context)).to eq(context)
      end

      it "wraps hash context in Agents::Context" do
        agent = TestAgent.new(context: { user: "John" })
        expect(agent.instance_variable_get(:@context)).to be_a(Agents::Context)
        expect(agent.instance_variable_get(:@context)[:user]).to eq("John")
      end
    end

    describe "#metadata" do
      it "returns agent metadata" do
        metadata = agent.metadata
        expect(metadata[:name]).to eq("Test Agent")
        expect(metadata[:instructions]).to eq("Test instructions")
        expect(metadata[:provider]).to eq(:openai)
        expect(metadata[:model]).to eq("gpt-4")
        expect(metadata[:tools]).to eq(["TestTool"])
      end
    end

    describe "#call" do
      let(:chat) { instance_double(RubyLLM::Chat) }
      let(:response) { double("response", content: "AI response", tool_calls: nil) }

      before do
        allow(RubyLLM).to receive(:chat).and_return(chat)
        allow(chat).to receive_messages(with_instructions: chat, with_tool: chat, ask: response, complete: response)
        allow(chat).to receive(:add_message)
      end

      it "executes a conversation turn" do
        result = agent.call("Hello")
        expect(result).to be_a(Agents::AgentResponse)
        expect(result.content).to eq("AI response")
        expect(result.handoff_result).to be_nil
      end

      it "sets system instructions" do
        agent.call("Hello")
        expect(chat).to have_received(:with_instructions).with("Test instructions")
      end

      it "adds tools to chat" do
        agent.call("Hello")
        expect(chat).to have_received(:with_tool).exactly(1).time
      end

      it "handles dynamic instructions" do
        context[:user] = "John"
        agent = DynamicAgent.new(context: context)

        agent.call("Hello")
        expect(chat).to have_received(:with_instructions).with("Instructions for John")
      end

      it "handles prepared input arrays from Runner" do
        prepared_input = [
          { role: "user", content: "Previous message" },
          { role: "assistant", content: "Previous response" },
          { role: "user", content: "Current message" }
        ]

        allow(chat).to receive(:add_message)
        allow(chat).to receive(:complete).and_return(response)

        agent.call(prepared_input)

        expect(chat).to have_received(:add_message).with(role: :user, content: "Previous message")
        expect(chat).to have_received(:add_message).with(role: :assistant, content: "Previous response")
        expect(chat).to have_received(:add_message).with(role: :user, content: "Current message")
        expect(chat).to have_received(:complete)
      end

      it "detects handoffs from context" do
        # The handoff should be set after the LLM response, not before
        # We'll simulate this by stubbing the ask method to set the handoff
        allow(chat).to receive(:ask) do |_input|
          # Simulate a tool (HandoffTool) setting the pending handoff during execution
          context[:pending_handoff] = {
            target_agent_class: HandoffTargetAgent,
            reason: "Transferring to target"
          }
          response
        end

        result = agent.call("Transfer me")
        expect(result.handoff_result).to be_a(Agents::HandoffResult)
        expect(result.handoff_result.target_agent_class).to eq(HandoffTargetAgent)
        expect(result.handoff_result.reason).to eq("Transferring to target")
      end

      it "clears pending handoff after detection" do
        context[:pending_handoff] = {
          target_agent_class: HandoffTargetAgent,
          reason: "Transferring"
        }

        agent.call("Transfer me")
        expect(context[:pending_handoff]).to be_nil
      end

      it "includes handoff tools when handoffs are defined" do
        agent = HandoffSourceAgent.new(context: context)
        agent.call("Hello")
        expect(chat).to have_received(:with_tool).exactly(1).time # 1 handoff tool
      end

      it "handles tool calls in response" do
        tool_call = double(
          "tool_call",
          id: "call_123",
          name: "test_tool",
          arguments: { input: "test" },
          result: "Tool result"
        )
        response_with_tools = double(
          "response",
          content: "AI response",
          tool_calls: [tool_call]
        )
        allow(chat).to receive(:ask).and_return(response_with_tools)

        result = agent.call("Use the tool")
        expect(result).to be_a(Agents::AgentResponse)
        expect(result.tool_calls).to eq([{
                                          id: "call_123",
                                          name: "test_tool",
                                          arguments: { input: "test" },
                                          result: "Tool result"
                                        }])
      end
    end

    describe "error handling" do
      let(:chat) { instance_double(RubyLLM::Chat) }

      before do
        allow(RubyLLM).to receive(:chat).and_return(chat)
        allow(chat).to receive_messages(with_instructions: chat, with_tool: chat)
      end

      it "handles RubyLLM errors" do
        # Create a custom error class that inherits from RubyLLM::Error for testing
        # We can't instantiate RubyLLM::Error directly as it expects a response object
        test_error_class = Class.new(RubyLLM::Error) do
          def initialize(message)
            super()
            @message = message
          end

          attr_reader :message
        end

        error = test_error_class.new("API error")
        allow(chat).to receive(:ask).and_raise(error)

        expect do
          agent.call("Hello")
        end.to raise_error(Agents::Agent::ExecutionError, /LLM error: API error/)
      end

      it "handles general errors" do
        allow(chat).to receive(:ask).and_raise(StandardError, "Unknown error")

        expect do
          agent.call("Hello")
        end.to raise_error(Agents::Agent::ExecutionError, /Agent execution failed: Unknown error/)
      end
    end
  end
end
