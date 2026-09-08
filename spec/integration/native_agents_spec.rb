# frozen_string_literal: true

require "webmock/rspec"

RSpec.describe Agents::Agent do
  include OpenAITestHelper

  before do
    setup_openai_test_config
    disable_net_connect!
  end

  after { allow_net_connect! }

  it "builds a native RubyLLM agent with runtime inputs and preserves its configuration" do
    native_agent = Class.new(RubyLLM::Agent) do
      model "gpt-4o"
      inputs :customer
      instructions { "Help #{customer}" }
      max_output_tokens 100
      provider_options top_p: 0.8
      schema type: "object", properties: { answer: { type: "string" } }, required: ["answer"]
    end
    agent = described_class.new(name: "Support", chat: ->(context) {
      native_agent.new(customer: context.context[:customer])
    })
    stub_simple_chat('{"answer":"Hello Alice"}')

    result = Agents::Runner.with_agents(agent).run("Hello", context: { customer: "Alice" })

    expect(result.error).to be_nil
    expect(result.output).to eq("answer" => "Hello Alice")
    expect(result.chat.messages.first.content).to eq("Help Alice")
    expect(result.chat.max_output_tokens).to eq(100)
    expect(result.chat.provider_options).to eq(top_p: 0.8)
  end

  it "does not carry native-only settings into a handoff target" do
    target = described_class.new(name: "Target", model: "gpt-4o-mini")
    source = described_class.new(name: "Source", handoff_agents: [target], chat: lambda { |_context|
      RubyLLM.chat(model: "gpt-4o").with_max_output_tokens(100).with_end_user("account_1")
             .with_fallbacks("gpt-4o-mini").with_provider_options(top_p: 0.8)
    })
    stub_chat_sequence({ tool_calls: [{ name: "handoff_to_target", arguments: {} }] }, "Done")

    result = Agents::Runner.with_agents(source, target).run("Help")

    expect(result.error).to be_nil
    expect(result.chat.max_output_tokens).to be_nil
    expect(result.chat.end_user).to be_nil
    expect(result.chat.fallbacks).to be_empty
    expect(result.chat.provider_options).to be_empty
  end

  it "resumes an approved tool round before completing its pending handoff" do
    tool = Class.new(Agents::Tool) do
      requires_approval
      def name = "publish"

      def perform(context)
        context.state[:published] = true
        "Published"
      end
    end
    target = described_class.new(name: "Target", model: "gpt-4o-mini")
    source = described_class.new(name: "Source", model: "gpt-4o", handoff_agents: [target], tools: [tool.new])
    stub_chat_sequence({ tool_calls: [
                         { id: "handoff_1", name: "handoff_to_target", arguments: {} },
                         { id: "publish_1", name: "publish", arguments: {} }
                       ] }, "Done")
    runner = Agents::Runner.with_agents(source, target)
    paused = runner.run("Publish", headers: { "X-Tenant" => "1" }, params: { top_p: 0.8 })

    expect(paused.awaiting_approval?).to be true
    expect(paused.context[:state]).to be_nil
    paused.chat.approve("publish_1")
    result = runner.resume(paused, headers: nil, params: { top_p: 0.9 })

    expect(result.error).to be_nil
    expect(result.output).to eq("Done")
    expect(result.context[:state][:published]).to be true
    expect(result.context[:current_agent]).to eq("Target")
    expect(result.context[:pending_handoff]).to be_nil
    expect(result.usage.entries.size).to eq(1)
    expect(result.chat.headers).to eq("X-Tenant": "1")
    expect(result.chat.provider_options).to eq(top_p: 0.9)
    expect(result.messages.count { |message| message[:tool_call_id] == "handoff_1" }).to eq(1)
  end

  it "resumes a denied native tool without executing it" do
    tool = Class.new(RubyLLM::Tool) do
      requires_approval
      def name = "publish"
      def execute = raise("Must not execute")
    end
    agent = described_class.new(name: "Support", chat: ->(_context) { RubyLLM.chat(model: "gpt-4o").with_tools(tool) })
    stub_chat_sequence({ tool_calls: [{ id: "publish_1", name: "publish", arguments: {} }] }, "Cancelled")
    runner = Agents::Runner.with_agents(agent)
    paused = runner.run("Publish")
    paused.chat.deny("publish_1")

    result = runner.resume(paused)

    expect(result.error).to be_nil
    expect(result.output).to eq("Cancelled")
    expect(result.messages.find { |message| message[:tool_call_id] == "publish_1" }[:content]).to include("denied")
  end

  it "retains the source identity and pending handoff when the target factory fails" do
    attempts = 0
    target = described_class.new(name: "Target", chat: lambda { |_context|
      attempts += 1
      raise "Configuration unavailable" if attempts == 1

      RubyLLM.chat(model: "gpt-4o-mini")
    })
    source = described_class.new(name: "Source", model: "gpt-4o", handoff_agents: [target])
    stub_chat_sequence({ tool_calls: [{ name: "handoff_to_target", arguments: {} }] }, "Done")
    runner = Agents::Runner.with_agents(source, target)

    failed = runner.run("Help")

    expect(failed.error.message).to eq("Configuration unavailable")
    expect(failed.context[:current_agent]).to eq("Source")
    expect(failed.chat.model.id).to eq("gpt-4o")
    result = runner.resume(failed)
    expect(result.error).to be_nil
    expect(result.context[:current_agent]).to eq("Target")
    expect(result.chat.model.id).to eq("gpt-4o-mini")
  end

  it "does not replace the configuration of an explicitly supplied chat" do
    native_context = RubyLLM.context { |config| config.request_timeout = 7 }
    chat = native_context.chat(model: "gpt-4o").with_max_output_tokens(50)
    agent = described_class.new(name: "Support")
    stub_simple_chat("Done")

    result = Agents::Runner.with_agents(agent).run("Help", chat: chat)

    expect(result.error).to be_nil
    expect(result.chat).to be(chat)
    expect(chat.context).to be(native_context)
    expect(chat.max_output_tokens).to eq(50)
    expect(native_context.config.instrumenter).to eq(RubyLLM.config.instrumenter)
  end

  it "keeps native configuration factories when cloning agent identity" do
    factory = ->(_context) { RubyLLM.chat(model: "gpt-4o") }
    agent = described_class.new(name: "Original", chat: factory)

    expect(agent.clone(name: "Copy").chat_factory).to be(factory)
    expect { described_class.new(name: "Mixed", model: "gpt-4o", chat: factory) }.to raise_error(ArgumentError)
  end

  it "runs tool rounds with RubyLLM's default OpenAI Responses protocol" do
    tool = Class.new(RubyLLM::Tool) do
      def name = "lookup"
      def execute(id:) = "Found #{id}"
    end
    native_context = RubyLLM.context do |config|
      config.openai_protocol = RubyLLM::Configuration.new.openai_protocol
    end
    agent = described_class.new(name: "Support", chat: ->(_context) {
      native_context.chat(model: "gpt-4o").with_tools(tool)
    })
    responses = [
      [{ type: "function_call", id: "fc_1", call_id: "call_1", name: "lookup", arguments: '{"id":123}' }],
      [{ type: "message", id: "msg_1", role: "assistant",
         content: [{ type: "output_text", text: "Done", annotations: [] }] }]
    ].map do |output|
      { status: 200, headers: { "Content-Type" => "application/json" },
        body: { id: "resp_1", object: "response", status: "completed", model: "gpt-4o", output: output,
                usage: { input_tokens: 10, output_tokens: 5, total_tokens: 15 } }.to_json }
    end
    stub_request(:post, "https://api.openai.com/v1/responses").to_return(*responses)

    result = Agents::Runner.with_agents(agent).run("Find 123")

    expect(result.error).to be_nil
    expect(result.output).to eq("Done")
    expect(result.usage.input_tokens).to eq(20)
    expect(WebMock).to have_requested(:post, "https://api.openai.com/v1/responses").twice
    expect(result.messages.find { |message| message[:tool_call_id] == "call_1" }[:content]).to eq("Found 123")
  end

  it "honors native cancellation without starting a provider request" do
    agent = described_class.new(name: "Support")
    chat = RubyLLM.chat(model: "gpt-4o")
    chat.cancel

    result = Agents::Runner.with_agents(agent).run("Help", chat: chat)

    expect(result.error).to be_a(RubyLLM::CancelledError)
    expect(result.usage.entries).to be_empty
    expect(WebMock).not_to have_requested(:post, "https://api.openai.com/v1/chat/completions")
  end

  it "lets RubyLLM handle fallbacks and accounts for both provider attempts" do
    native_context = RubyLLM.context { |config| config.max_retries = 0 }
    agent = described_class.new(name: "Support", chat: lambda { |_context|
      native_context.chat(model: "gpt-4o").with_fallbacks("gpt-4o-mini")
    })
    stub_simple_chat("Backup answer", model: "gpt-4o-mini")
    stub_request(:post, "https://api.openai.com/v1/chat/completions")
      .with { |request| JSON.parse(request.body)["model"] == "gpt-4o" }
      .to_return(status: 503, body: { error: { message: "Unavailable" } }.to_json,
                 headers: { "Content-Type" => "application/json" })

    result = Agents::Runner.with_agents(agent).run("Help", max_turns: 1)

    expect(result.error).to be_nil
    expect(result.output).to eq("Backup answer")
    expect(result.usage.entries.map { |entry| entry[:status] }).to eq(%i[failed succeeded])
    expect(result.usage.input_tokens).to eq(10)
    expect(result.usage.cost.total).to be_nil
  end
end
