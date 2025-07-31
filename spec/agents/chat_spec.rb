# frozen_string_literal: true

require "webmock/rspec"
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
  let(:handoff_tool) do
    instance_double(Agents::HandoffTool, "HandoffTool", name: "handoff_to_support_agent",
                                                        description: "Transfer to support agent", parameters: {})
  end
  let(:target_agent) { instance_double(Agents::Agent, name: "Support Agent") }

  describe "#classify_tool_calls" do
    let(:chat) { described_class.new(handoff_tools: [handoff_tool], context_wrapper: context) }

    it "separates handoff tools from regular tools" do
      allow(handoff_tool).to receive(:name).and_return("handoff_to_support_agent")

      tool_calls = {
        "1" => instance_double(RubyLLM::ToolCall, name: "regular_tool"),
        "2" => instance_double(RubyLLM::ToolCall, name: "handoff_to_support_agent")
      }

      handoff_calls, regular_calls = chat.send(:classify_tool_calls, tool_calls)

      expect(handoff_calls.size).to eq(1)
      expect(regular_calls.size).to eq(1)
      expect(handoff_calls.first.name).to eq("handoff_to_support_agent")
      expect(regular_calls.first.name).to eq("regular_tool")
    end
  end

  describe "HandoffResponse" do
    let(:mock_response) { instance_double(RubyLLM::Message, content: "original response") }
    let(:handoff_response) do
      described_class::HandoffResponse.new(
        target_agent: target_agent,
        response: mock_response,
        handoff_message: "Transfer message"
      )
    end

    it "stores target agent and message" do
      expect(handoff_response.target_agent).to eq(target_agent)
      expect(handoff_response.handoff_message).to eq("Transfer message")
      expect(handoff_response.response).to eq(mock_response)
    end

    it "returns true for tool_call?" do
      expect(handoff_response.tool_call?).to be true
    end

    it "returns handoff message as content" do
      expect(handoff_response.content).to eq("Transfer message")
    end
  end

  describe "#execute_handoff_tool" do
    let(:chat) { described_class.new(handoff_tools: [handoff_tool], context_wrapper: context) }
    let(:tool_call) { instance_double(RubyLLM::ToolCall, name: "handoff_to_support_agent") }

    it "executes handoff tool and returns result hash" do
      allow(handoff_tool).to receive_messages(name: "handoff_to_support_agent", target_agent: target_agent,
                                              execute: "Transfer message")
      allow(Agents::ToolContext).to receive(:new).and_return(instance_double(Agents::ToolContext))

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

    it "registers handoff tools with RubyLLM" do
      chat = described_class.new(handoff_tools: [handoff_tool], context_wrapper: context)
      expect(chat.instance_variable_get(:@handoff_tools)).to eq([handoff_tool])
    end

    it "accepts temperature parameter" do
      chat = described_class.new(temperature: 0.5, handoff_tools: [], context_wrapper: context)

      expect(chat.instance_variable_get(:@temperature)).to eq(0.5)
    end

    it "sets temperature after initialization" do
      chat = described_class.new(model: "gpt-4", temperature: 0.8, handoff_tools: [], context_wrapper: context)

      expect(chat.instance_variable_get(:@temperature)).to eq(0.8)
    end

    it "accepts response_schema parameter" do
      schema = { type: "object", properties: { answer: { type: "string" } } }

      expect do
        described_class.new(
          model: "gpt-4o",
          response_schema: schema
        )
      end.not_to raise_error
    end

    it "accepts nil response_schema" do
      expect do
        described_class.new(
          model: "gpt-4o",
          response_schema: nil
        )
      end.not_to raise_error
    end

    it "calls with_schema when response_schema is provided" do
      schema = { type: "object", properties: { answer: { type: "string" } } }
      chat = described_class.new(model: "gpt-4o", response_schema: schema)

      # Since with_schema is called during initialization and modifies @schema,
      # we can verify it was called by checking the schema attribute
      expect(chat.schema).to eq(schema)
    end

    it "inherits from RubyLLM::Chat" do
      expect(described_class < RubyLLM::Chat).to be true
    end
  end

  describe "#complete" do
    let(:chat) { described_class.new(handoff_tools: [handoff_tool], context_wrapper: context) }

    before do
      WebMock.disable_net_connect!
    end

    after do
      WebMock.allow_net_connect!
    end

    context "when response has no tool calls" do
      before do
        stub_request(:post, "https://api.openai.com/v1/chat/completions")
          .to_return(
            status: 200,
            body: {
              id: "chatcmpl-123",
              object: "chat.completion",
              created: 1_677_652_288,
              model: "gpt-4.1-mini",
              choices: [{
                index: 0,
                message: {
                  role: "assistant",
                  content: "Regular response"
                },
                finish_reason: "stop"
              }],
              usage: {
                prompt_tokens: 10,
                completion_tokens: 20,
                total_tokens: 30
              }
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns the response directly" do
        result = chat.complete

        expect(result.content).to eq("Regular response")
        expect(result.tool_call?).to be false
      end
    end

    context "when response has handoff tool calls" do
      before do
        allow(handoff_tool).to receive_messages(target_agent: target_agent, execute: "Transferring to support")
        allow(Agents::ToolContext).to receive(:new).and_return(instance_double(Agents::ToolContext))

        stub_request(:post, "https://api.openai.com/v1/chat/completions")
          .to_return(
            status: 200,
            body: {
              id: "chatcmpl-456",
              object: "chat.completion",
              created: 1_677_652_288,
              model: "gpt-4.1-mini",
              choices: [{
                index: 0,
                message: {
                  role: "assistant",
                  content: nil,
                  tool_calls: [{
                    id: "call_123",
                    type: "function",
                    function: {
                      name: "handoff_to_support_agent",
                      arguments: "{}"
                    }
                  }]
                },
                finish_reason: "tool_calls"
              }],
              usage: {
                prompt_tokens: 15,
                completion_tokens: 5,
                total_tokens: 20
              }
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "executes handoff and returns HandoffResponse" do
        result = chat.complete

        expect(result).to be_a(described_class::HandoffResponse)
        expect(result.target_agent).to eq(target_agent)
        expect(result.handoff_message).to eq("Transferring to support")
      end
    end

    context "when response has regular tool calls" do
      before do
        allow(chat).to receive(:tools).and_return({ regular_tool: regular_tool })
        allow(regular_tool).to receive(:call).with({}).and_return("tool result")

        # First response with tool call
        stub_request(:post, "https://api.openai.com/v1/chat/completions")
          .to_return(
            {
              status: 200,
              body: {
                id: "chatcmpl-789",
                object: "chat.completion",
                created: 1_677_652_288,
                model: "gpt-4.1-mini",
                choices: [{
                  index: 0,
                  message: {
                    role: "assistant",
                    content: nil,
                    tool_calls: [{
                      id: "call_456",
                      type: "function",
                      function: {
                        name: "regular_tool",
                        arguments: "{}"
                      }
                    }]
                  },
                  finish_reason: "tool_calls"
                }],
                usage: { prompt_tokens: 20, completion_tokens: 5, total_tokens: 25 }
              }.to_json,
              headers: { "Content-Type" => "application/json" }
            },
            # Second response after tool execution
            {
              status: 200,
              body: {
                id: "chatcmpl-999",
                object: "chat.completion",
                created: 1_677_652_300,
                model: "gpt-4.1-mini",
                choices: [{
                  index: 0,
                  message: {
                    role: "assistant",
                    content: "Tool execution complete"
                  },
                  finish_reason: "stop"
                }],
                usage: { prompt_tokens: 25, completion_tokens: 15, total_tokens: 40 }
              }.to_json,
              headers: { "Content-Type" => "application/json" }
            }
          )
      end

      it "executes regular tools and continues conversation" do
        result = chat.complete

        expect(result.content).to eq("Tool execution complete")
        expect(result.tool_call?).to be false
      end
    end
  end

  describe "#add_tool_result" do
    let(:chat) { described_class.new(handoff_tools: [], context_wrapper: context) }

    it "adds tool result message with string content" do
      allow(chat).to receive(:add_message)

      chat.send(:add_tool_result, "call_123", "tool result")

      expect(chat).to have_received(:add_message).with(
        role: :tool,
        content: "tool result",
        tool_call_id: "call_123"
      )
    end

    it "adds tool result message with error hash" do
      error_result = { error: "Something went wrong" }
      allow(chat).to receive(:add_message)

      chat.send(:add_tool_result, "call_123", error_result)

      expect(chat).to have_received(:add_message).with(
        role: :tool,
        content: "Something went wrong",
        tool_call_id: "call_123"
      )
    end
  end

  describe "#execute_regular_tools_and_continue" do
    let(:chat) { described_class.new(handoff_tools: [], context_wrapper: context) }
    let(:tool_call) do
      instance_double(RubyLLM::ToolCall,
                      id: "call_456",
                      name: "test_tool",
                      arguments: { param: "value" })
    end
    let(:continued_response) do
      instance_double(RubyLLM::Message,
                      tool_call?: false,
                      content: "Continued response")
    end

    before do
      allow(chat).to receive(:instance_variable_get).with(:@on).and_return({})
      allow(regular_tool).to receive(:call).and_return("tool result")
      allow(chat).to receive_messages(tools: { test_tool: regular_tool }, add_tool_result: nil,
                                      complete: continued_response)
    end

    it "executes each tool call and continues conversation" do
      allow(chat).to receive(:execute_tool).with(tool_call).and_return("tool result")
      allow(chat).to receive(:add_tool_result).with("call_456", "tool result")
      allow(chat).to receive(:complete).and_return(continued_response)

      result = chat.send(:execute_regular_tools_and_continue, [tool_call])

      expect(result).to eq(continued_response)
      expect(chat).to have_received(:execute_tool).with(tool_call)
      expect(chat).to have_received(:add_tool_result).with("call_456", "tool result")
      expect(chat).to have_received(:complete)
    end
  end

  describe "#execute_tool" do
    let(:chat) { described_class.new(handoff_tools: [], context_wrapper: context) }
    let(:tool_call) do
      instance_double(RubyLLM::ToolCall,
                      name: "test_tool",
                      arguments: { param: "value" })
    end

    before do
      allow(chat).to receive(:tools).and_return({ test_tool: regular_tool })
    end

    it "calls the tool with arguments" do
      allow(regular_tool).to receive(:call).with({ param: "value" }).and_return("tool result")

      result = chat.send(:execute_tool, tool_call)

      expect(result).to eq("tool result")
      expect(regular_tool).to have_received(:call).with({ param: "value" })
    end
  end
end
