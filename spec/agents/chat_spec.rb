# frozen_string_literal: true

require_relative "../../lib/agents"

RSpec.describe Agents::Chat do
  before do
    # Configure RubyLLM for testing
    RubyLLM.configure do |config|
      config.openai_api_key = "test"
    end
  end

  let(:ruby_llm_chat) { instance_double(RubyLLM::Chat, "RubyLLMChat") }
  let(:context) { instance_double(Agents::RunContext, "RunContext") }
  let(:regular_tool) { instance_double(Agents::Tool, "RegularTool") }
  let(:handoff_tool) { instance_double(Agents::HandoffTool, "HandoffTool", name: "handoff_to_support_agent") }
  let(:target_agent) { instance_double(Agents::Agent, name: "Support Agent") }

  describe "#classify_tool_calls" do
    let(:chat) { described_class.new(handoff_tools: [handoff_tool], context_wrapper: context) }

    it "separates handoff tools from regular tools" do
      allow(handoff_tool).to receive(:name).and_return("handoff_to_support_agent")

      tool_calls = {
        "1" => instance_double(ToolCall, name: "regular_tool"),
        "2" => instance_double(ToolCall, name: "handoff_to_support_agent")
      }

      handoff_calls, regular_calls = chat.send(:classify_tool_calls, tool_calls)

      expect(handoff_calls.size).to eq(1)
      expect(regular_calls.size).to eq(1)
      expect(handoff_calls.first.name).to eq("handoff_to_support_agent")
      expect(regular_calls.first.name).to eq("regular_tool")
    end
  end

  describe "HandoffResponse" do
    let(:handoff_response) do
      described_class::HandoffResponse.new(target_agent: target_agent, response: "response",
                                           handoff_message: "Transfer message")
    end

    it "stores target agent and message" do
      expect(handoff_response.target_agent).to eq(target_agent)
      expect(handoff_response.handoff_message).to eq("Transfer message")
    end
  end

  describe "#execute_handoff_tool" do
    let(:chat) { described_class.new(handoff_tools: [handoff_tool], context_wrapper: context) }
    let(:tool_call) { instance_double(ToolCall, name: "handoff_to_support_agent") }

    it "executes handoff tool and returns result hash" do
      allow(handoff_tool).to receive_messages(name: "handoff_to_support_agent", target_agent: target_agent,
                                              execute: "Transfer message")
      allow(Agents::ToolContext).to receive(:new).and_return(double("ToolContext"))

      result = chat.send(:execute_handoff_tool, tool_call)

      expect(result[:target_agent]).to eq(target_agent)
      expect(result[:message]).to eq("Transfer message")
    end
  end

  describe "initialization" do
    it "stores handoff tools and context wrapper" do
      chat = described_class.new(handoff_tools: [handoff_tool], context_wrapper: context)

      expect(chat.instance_variable_get(:@handoff_tools)).to eq([handoff_tool])
      expect(chat.instance_variable_get(:@context_wrapper)).to eq(context)
    end
  end
end
