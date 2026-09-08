# frozen_string_literal: true

require "webmock/rspec"

RSpec.describe Agents::Runner do
  include OpenAITestHelper

  before do
    setup_openai_test_config
    disable_net_connect!
  end

  after { allow_net_connect! }

  let(:specialist) { Agents::Agent.new(name: "Specialist", model: "gpt-4o-mini") }
  let(:triage) do
    Agents::Agent.new(name: "Triage", model: "gpt-4o", instructions: "Route requests",
                      handoff_agents: [specialist], temperature: 0.7,
                      response_schema: { type: "object", properties: { answer: { type: "string" } } },
                      headers: { "X-Triage" => "yes" }, params: { top_p: 0.5 })
  end

  it "clears the previous agent's settings and preserves runtime options during handoff" do
    stub_chat_sequence({ tool_calls: [{ name: "handoff_to_specialist", arguments: {} }] }, "Specialist answer")

    result = described_class.with_agents(triage, specialist).run("Help", headers: { "X-Run" => "yes" })

    expect(result.error).to be_nil
    expect(result.output).to eq("Specialist answer")
    expect(result.chat.model.id).to eq("gpt-4o-mini")
    expect(result.chat.tools).to be_empty
    expect(result.chat.schema).to be_nil
    expect(result.chat.temperature).to be_nil
    expect(result.chat.headers).to eq("X-Run": "yes")
    expect(result.chat.provider_options).to be_empty
    expect(result.chat.messages.none? { |message| message.role == :system }).to be true
  end

  it "counts generations on both sides of a handoff" do
    stub_chat_sequence({ tool_calls: [{ name: "handoff_to_specialist", arguments: {} }] }, "Done")

    result = described_class.with_agents(triage, specialist).run("Help")

    expect(result.usage.input_tokens).to eq(30)
    expect(result.usage.output_tokens).to eq(13)
  end

  it "stops before another generation when a handoff exhausts the budget" do
    stub_chat_sequence({ tool_calls: [{ name: "handoff_to_specialist", arguments: {} }] }, "Must not run")

    result = described_class.with_agents(triage, specialist).run("Help", max_turns: 1)

    expect(result.error).to be_a(Agents::Runner::MaxTurnsExceeded)
    expect(result.context[:current_agent]).to eq("Specialist")
    expect(WebMock).to have_requested(:post, "https://api.openai.com/v1/chat/completions").once
  end

  it "does not repeat a user message already present in restored history" do
    stub_simple_chat("Done")
    context = { conversation_history: [{ role: :user, content: "Help" }] }

    result = described_class.with_agents(specialist).run("Help", context: context)

    expect(result.error).to be_nil
    expect(result.chat.messages.count { |message| message.role == :user }).to eq(1)
  end

  it "preserves author attribution through a return handoff" do
    specialist.register_handoffs(triage)
    stub_chat_sequence(
      { tool_calls: [{ name: "handoff_to_specialist", arguments: {} }] },
      { tool_calls: [{ name: "handoff_to_triage", arguments: {} }] },
      '{"answer":"Done"}'
    )

    result = described_class.with_agents(triage, specialist).run("Help")

    expect(result.error).to be_nil
    expect(result.messages.select { |message| message[:role] == :assistant }.map { |message| message[:agent_name] })
      .to eq(%w[Triage Specialist Triage])
  end

  it "keeps the current tools when an approval pauses a handoff round" do
    tool_class = Class.new(Agents::Tool) do
      requires_approval
      def name = "publish"
      def perform(_context) = "Published"
    end
    agent = triage.clone(tools: [tool_class.new])
    stub_tool_call_chat(tool_calls: [
                          { name: "handoff_to_specialist", arguments: {} },
                          { name: "publish", arguments: {} }
                        ])

    result = described_class.with_agents(agent, specialist).run("Publish")

    expect(result.error).to be_nil
    expect(result.chat.awaiting_approval?).to be true
    expect(result.context[:current_agent]).to eq("Triage")
    expect(result.chat.tools[:publish].requires_approval?).to be true
    expect(WebMock).to have_requested(:post, "https://api.openai.com/v1/chat/completions").once
  end

  it "supplies the handoff history and agent identity to dynamic instructions" do
    snapshots = []
    target = specialist.clone(instructions: lambda { |context|
      snapshots << [context.context[:current_agent], context.context[:conversation_history].map { |msg| msg[:role] }]
      "Continue helping"
    })
    agent = triage.clone(handoff_agents: [target])
    stub_chat_sequence({ tool_calls: [{ name: "handoff_to_specialist", arguments: {} }] }, "Done")

    result = described_class.with_agents(agent, target).run("Help")

    expect(result.error).to be_nil
    expect(snapshots).to eq([["Specialist", %i[user assistant tool]]])
    expect(result.context[:turn_count]).to eq(1)
  end
end
