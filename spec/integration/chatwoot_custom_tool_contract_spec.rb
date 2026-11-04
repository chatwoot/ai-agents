# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"

# Chatwoot admins build custom HTTP tools in the UI. Chatwoot turns each one into a tool class at runtime
# (enterprise/app/models/concerns/toolable.rb) and lets admins pick string, number, boolean, array and object
# parameters. These specs send such a tool through a real RubyLLM chat against stubbed HTTP on both protocols.
# They fail if a RubyLLM upgrade changes the tool schema Chatwoot depends on, for example by making tools strict,
# which rejects optional parameters and objects without properties.
module ChatwootCustomTools; end

# rubocop:disable RSpec/DescribeClass
RSpec.describe "Chatwoot custom tool contract" do
  include OpenAITestHelper

  let(:param_schema) do
    [
      { "name" => "order_id", "type" => "string", "description" => "Order id" },
      { "name" => "quantity", "type" => "number", "description" => "Number of items" },
      { "name" => "gift", "type" => "boolean", "description" => "Whether to gift wrap" },
      { "name" => "tags", "type" => "array", "description" => "Order tags" },
      { "name" => "metadata", "type" => "object", "description" => "Extra order data", "required" => false }
    ]
  end
  let(:arguments) do
    { order_id: "A1", quantity: 2, gift: true, tags: %w[red xl], metadata: { source: "web" } }
  end
  let(:received) { [] }
  let(:payloads) { [] }

  before do
    setup_openai_test_config
    disable_net_connect!
  end

  after do
    allow_net_connect!
  end

  # Mirrors Concerns::Toolable#tool: a fresh class per tool, the slug as its name, and params from admin input.
  def build_custom_tool(slug:, schema:, received:)
    tool_class = Class.new(Agents::Tool) do
      description "Look up an order"
      define_method(:name) { slug }
      define_method(:perform) do |_tool_context, **params|
        received << params
        "Order found"
      end

      schema.each do |param_def|
        parameter param_def["name"].to_sym,
                  type: param_def["type"],
                  description: param_def["description"],
                  required: param_def.fetch("required", true)
      end
    end
    stub_const("ChatwootCustomTools::OrderLookup", tool_class)
    tool_class.new
  end

  def run_agent(protocol:)
    tool = build_custom_tool(slug: "order_lookup", schema: param_schema, received: received)
    agent = Agents::Agent.new(name: "Captain", model: "gpt-4o", protocol: protocol, tools: [tool])
    Agents::Runner.with_agents(agent).run("Look up order A1")
  end

  def json_response(body)
    { status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" } }
  end

  def expect_param_schema(parameters)
    expect(parameters["properties"]).to include(
      "order_id" => include("type" => "string"),
      "quantity" => include("type" => "number"),
      "gift" => include("type" => "boolean"),
      "tags" => include("type" => "array", "items" => include("type" => "string")),
      "metadata" => include("type" => "object")
    )
    expect(parameters["required"]).to contain_exactly("order_id", "quantity", "gift", "tags")
  end

  def expect_arguments_received
    expect(received).to contain_exactly(
      include(order_id: "A1", quantity: 2, gift: true, tags: %w[red xl], metadata: include("source" => "web"))
    )
  end

  context "with chat completions" do
    before do
      responses = [
        build_tool_call_response([{ id: "call_1", name: "order_lookup", arguments: arguments }]),
        build_simple_response("Your order is on the way")
      ]
      stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return do |request|
        payloads << JSON.parse(request.body)
        json_response(responses.shift)
      end
    end

    it "sends every admin parameter type and passes the arguments to the tool" do
      result = run_agent(protocol: :chat_completions)

      expect(result.error).to be_nil
      function = payloads.first["tools"].first["function"]
      expect(function["name"]).to eq("order_lookup")
      expect(function["strict"]).not_to be(true)
      expect_param_schema(function["parameters"])
      expect_arguments_received
    end
  end

  context "with responses" do
    before do
      usage = { input_tokens: 12, output_tokens: 8 }
      responses = [
        { id: "resp_1", status: "completed", model: "gpt-4o", usage: usage,
          output: [{ type: "function_call", call_id: "call_1", name: "order_lookup",
                     arguments: arguments.to_json }] },
        { id: "resp_2", status: "completed", model: "gpt-4o", usage: usage,
          output: [{ type: "message", role: "assistant",
                     content: [{ type: "output_text", text: "Your order is on the way" }] }] }
      ]
      stub_request(:post, "https://api.openai.com/v1/responses").to_return do |request|
        payloads << JSON.parse(request.body)
        json_response(responses.shift)
      end
    end

    it "sends every admin parameter type as a non-strict tool and passes the arguments to the tool" do
      result = run_agent(protocol: :responses)

      expect(result.error).to be_nil
      tool = payloads.first["tools"].first
      expect(tool).to include("type" => "function", "name" => "order_lookup", "strict" => false)
      expect_param_schema(tool["parameters"])
      expect_arguments_received
    end
  end
end
# rubocop:enable RSpec/DescribeClass
