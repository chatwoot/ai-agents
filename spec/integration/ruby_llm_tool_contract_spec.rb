# frozen_string_literal: true

require "webmock/rspec"
require_relative "../../lib/agents"

# ToolWrapper duck-types RubyLLM::Tool. Most runner specs mock RubyLLM::Chat,
# so they never reach the methods RubyLLM calls on registered tools.
# These specs run a real chat against stubbed HTTP to catch interface drift.
RSpec.describe Agents::ToolWrapper do
  include OpenAITestHelper

  let(:tool_class) do
    Class.new(Agents::Tool) do
      description "Add two integers"
      param :first, type: "integer", description: "First addend"
      param :second, type: "integer", description: "Second addend"

      def name
        "add_numbers"
      end

      def perform(_tool_context, first:, second:)
        first + second
      end
    end
  end

  let(:payloads) { [] }

  before do
    setup_openai_test_config
    disable_net_connect!
  end

  after do
    allow_net_connect!
  end

  def run_agent(protocol:)
    agent = Agents::Agent.new(name: "Calculator", model: "gpt-4o", protocol: protocol, tools: [tool_class.new])
    Agents::Runner.with_agents(agent).run("Add 2 and 3")
  end

  def json_response(body)
    { status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" } }
  end

  context "with chat completions" do
    before do
      responses = [
        build_tool_call_response([{ id: "call_1", name: "add_numbers", arguments: { first: 2, second: 3 } }]),
        build_simple_response("The sum is 5")
      ]
      stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return do |request|
        payloads << JSON.parse(request.body)
        json_response(responses.shift)
      end
    end

    it "sends the wrapped tool definition and returns the tool result to the model" do
      result = run_agent(protocol: :chat_completions)

      expect(result.error).to be_nil
      expect(result.output).to eq("The sum is 5")
      expect(payloads.first["tools"]).to contain_exactly(
        hash_including(
          "type" => "function",
          "function" => hash_including(
            "name" => "add_numbers",
            "description" => "Add two integers",
            "parameters" => hash_including("properties" => hash_including("first", "second"))
          )
        )
      )
      expect(payloads.last["messages"]).to include(
        hash_including("role" => "tool", "tool_call_id" => "call_1", "content" => "5")
      )
    end
  end

  context "with responses" do
    before do
      usage = { input_tokens: 12, output_tokens: 8 }
      arguments = { first: 2, second: 3 }.to_json
      responses = [
        { id: "resp_1", status: "completed", model: "gpt-4o", usage: usage,
          output: [{ type: "function_call", call_id: "call_1", name: "add_numbers", arguments: arguments }] },
        { id: "resp_2", status: "completed", model: "gpt-4o", usage: usage,
          output: [{ type: "message", role: "assistant", content: [{ type: "output_text", text: "The sum is 5" }] }] }
      ]
      stub_request(:post, "https://api.openai.com/v1/responses").to_return do |request|
        payloads << JSON.parse(request.body)
        json_response(responses.shift)
      end
    end

    it "sends the wrapped tool definition and returns the tool result to the model" do
      result = run_agent(protocol: :responses)

      expect(result.error).to be_nil
      expect(result.output).to eq("The sum is 5")
      expect(payloads.first["tools"]).to contain_exactly(
        hash_including(
          "type" => "function",
          "name" => "add_numbers",
          "description" => "Add two integers",
          "parameters" => hash_including("properties" => hash_including("first", "second"))
        )
      )
      expect(payloads.last["input"]).to include(
        hash_including("type" => "function_call_output", "call_id" => "call_1", "output" => "5")
      )
    end
  end
end
