# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"
require "agents/instrumentation"
require "opentelemetry-sdk"

# Each example mirrors one path that Chatwoot's Captain runs in production. See spec/support/chatwoot_live_helper.rb.
# rubocop:disable RSpec/DescribeClass
RSpec.describe "Live Chatwoot contract", :live_llm do
  include ChatwootLiveHelper

  let(:events) { [] }
  let(:span_exporter) { OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new }
  let(:faq_tool) { ChatwootLiveHelper::FaqLookupTool.new }
  let(:handoff_tool) { ChatwootLiveHelper::HandoffTool.new }
  let(:image_url) do
    "https://raw.githubusercontent.com/chatwoot/ai-agents/main/spec/fixtures/dice_transparency.png"
  end

  around { |example| with_chatwoot_llm_config { example.run } }

  def events_of(type)
    events.select { |event| event.first == type }
  end

  it "replies in the response schema over the Responses API with reasoning effort none" do
    assistant = chatwoot_agent(name: "Captain", prompt: "Greet the customer by name.", tools: [faq_tool])
    runner = chatwoot_runner(wire_chatwoot_agents(assistant), events: events, span_exporter: span_exporter)

    result = run_like_chatwoot(runner, [{ role: "user", content: "Hi! Do you know my name?" }],
                               state: { contact: { name: "Priya" } })

    expect(result.error).to be_nil
    expect(result.output).to be_a(Hash)
    expect(result.output["response_parts"]).to all(include("text" => a_string_matching(/\S/)))
    expect(response_text(result.output)).to match(/priya/i)

    request = openrouter_requests(ChatwootLiveHelper::RESPONSES_URL).last
    expect(request).to include("model" => chatwoot_model, "temperature" => 0.5, "reasoning" => { "effort" => "none" })
    expect(request.dig("text", "format")).to include("type" => "json_schema")

    generation = span_exporter.finished_spans.find { |span| span.name == "llm.captain_v2.generation" }
    expect(generation.attributes).to include(
      "gen_ai.request.model" => chatwoot_model,
      "langfuse.observation.metadata.provider" => "openai",
      "langfuse.observation.metadata.reasoning_effort" => "none"
    )
    expect(events_of(:run_complete).size).to eq(1)
  end

  it "calls a tool and keeps the state it writes in the same run" do
    assistant = chatwoot_agent(
      name: "Captain", tools: [faq_tool],
      prompt: "Always search the FAQ with the #{faq_tool.name} tool before you answer. Answer only from FAQ results."
    )
    runner = chatwoot_runner(wire_chatwoot_agents(assistant), events: events, span_exporter: span_exporter)

    result = run_like_chatwoot(runner, [{ role: "user", content: "How long do refunds take?" }])

    expect(result.error).to be_nil
    expect(response_text(result.output)).to include("11")
    expect(result.context.dig(:state, :cw_metadata, :faq_ids)).to eq([ChatwootLiveHelper::FaqLookupTool::FAQ_ID])
    tool_event = events_of(:tool_complete).find { |event| event[1] == faq_tool.name }
    expect(tool_event[2]).to include(ChatwootLiveHelper::FaqLookupTool::ANSWER)
    expect(span_exporter.finished_spans.map(&:name)).to include("llm.captain_v2.tool.#{faq_tool.name}")
  end

  it "calls a handoff tool declared with an enum parameter" do
    assistant = chatwoot_agent(
      name: "Captain", tools: [faq_tool, handoff_tool],
      prompt: "If the customer asks for a human, call the #{handoff_tool.name} tool with " \
              "reason_category customer_request. Then tell the customer a human will reply soon."
    )
    runner = chatwoot_runner(wire_chatwoot_agents(assistant), events: events, span_exporter: span_exporter)

    result = run_like_chatwoot(runner, [{ role: "user", content: "Please connect me to a human agent." }])

    expect(result.error).to be_nil
    tool_event = events_of(:tool_complete).find { |event| event[1] == handoff_tool.name }
    expect(tool_event[2]).to start_with("Conversation handed off")
    expect(tool_event[3]).to include(captain_v2_handoff_tool_completed: true)
    expect(ChatwootLiveHelper::HandoffTool::REASON_CATEGORIES).to include(result.context.dig(:state,
                                                                                             :handoff_reason_category))

    tools = openrouter_requests(ChatwootLiveHelper::RESPONSES_URL).first["tools"]
    handoff_schema = tools.find { |tool| tool["name"] == handoff_tool.name }
    expect(handoff_schema.dig("parameters", "properties", "reason_category", "enum"))
      .to eq(ChatwootLiveHelper::HandoffTool::REASON_CATEGORIES)
  end

  it "hands off from the assistant to a scenario agent" do
    scenario = chatwoot_agent(
      name: "Refunds", tools: [faq_tool],
      prompt: "You handle refund requests. Ask the customer for their order number."
    )
    assistant = chatwoot_agent(
      name: "Captain", tools: [faq_tool],
      prompt: "You do not handle refunds. For any refund request, transfer the conversation to Refunds " \
              "with the handoff tool before you reply."
    )
    runner = chatwoot_runner(wire_chatwoot_agents(assistant, [scenario]), events: events, span_exporter: span_exporter)

    result = run_like_chatwoot(runner, [{ role: "user", content: "I want a refund for my broken mug." }])

    expect(result.error).to be_nil
    expect(events_of(:agent_handoff)).to include([:agent_handoff, "Captain", "Refunds"])
    expect(result.context[:current_agent]).to eq("Refunds")
    expect(result.output["response_parts"]).not_to be_empty
  end

  it "resumes the scenario agent from a rebuilt history with consecutive user messages" do
    scenario = chatwoot_agent(name: "Refunds", prompt: "You handle refund requests.")
    assistant = chatwoot_agent(name: "Captain", prompt: "Answer general questions.")
    runner = chatwoot_runner(wire_chatwoot_agents(assistant, [scenario]), events: events, span_exporter: span_exporter)
    question = "Can I get a refund? Also tell me the color of the mug I ordered."
    message_history = [
      { role: "user", content: "Hi, I ordered a blue mug last week." },
      { role: "assistant", content: "Thanks! How can I help with your order?", agent_name: "Refunds" },
      { role: "assistant", content: ChatwootLiveHelper::RESOLUTION_MARKER },
      { role: "user", content: "It arrived broken." },
      { role: "user", content: question }
    ]

    result = run_like_chatwoot(runner, message_history)

    expect(result.error).to be_nil
    expect(events_of(:agent_thinking).first[1]).to eq("Refunds")
    expect(response_text(result.output)).to match(/blue/i)
    sent = user_texts(openrouter_requests(ChatwootLiveHelper::RESPONSES_URL).first)
    expect(sent).to eq(["Hi, I ordered a blue mug last week.", "It arrived broken.", question])
  end

  it "answers a multimodal input message with an image URL" do
    assistant = chatwoot_agent(name: "Captain", prompt: "Describe images the customer sends.")
    runner = chatwoot_runner(wire_chatwoot_agents(assistant), events: events, span_exporter: span_exporter)
    message_history = [
      {
        role: "user",
        content: [
          { type: "text", text: "How many dice are in this image?" },
          { type: "image_url", image_url: { url: image_url } }
        ]
      }
    ]

    result = run_like_chatwoot(runner, message_history)

    expect(result.error).to be_nil
    expect(response_text(result.output).downcase).to match(/four|4/)
    content = openrouter_requests(ChatwootLiveHelper::RESPONSES_URL).first["input"]
                                                                    .find { |item| item["role"] == "user" }["content"]
    expect(content).to include(include("type" => "input_image"))
  end

  it "runs a tool with the response schema over chat completions for a self-hosted endpoint" do
    assistant = chatwoot_agent(
      name: "Captain", tools: [faq_tool], protocol: nil,
      prompt: "Always search the FAQ with the #{faq_tool.name} tool before you answer. Answer only from FAQ results."
    )
    runner = chatwoot_runner(wire_chatwoot_agents(assistant), events: events, span_exporter: span_exporter)

    result = run_like_chatwoot(runner, [{ role: "user", content: "How long do refunds take?" }])

    expect(result.error).to be_nil
    expect(response_text(result.output)).to include("11")
    requests = openrouter_requests(ChatwootLiveHelper::CHAT_COMPLETIONS_URL)
    expect(requests.size).to be >= 2
    expect(requests.first).not_to have_key("reasoning")
    expect(requests.first.dig("response_format", "type")).to eq("json_schema")
    expect(openrouter_requests(ChatwootLiveHelper::RESPONSES_URL)).to be_empty
  end

  it "replays reasoning between tool calls in one run with reasoning effort low" do
    assistant = chatwoot_agent(
      name: "Captain", tools: [faq_tool], reasoning_effort: :low, model: chatwoot_reasoning_model,
      prompt: "Always search the FAQ with the #{faq_tool.name} tool before you answer. Answer only from FAQ results."
    )
    runner = chatwoot_runner(wire_chatwoot_agents(assistant), events: events, span_exporter: span_exporter)

    result = run_like_chatwoot(runner, [{ role: "user", content: "How long do refunds take?" }])

    expect(result.error).to be_nil
    expect(response_text(result.output)).to include("11")
    requests = openrouter_requests(ChatwootLiveHelper::RESPONSES_URL)
    expect(requests.first).not_to have_key("temperature")
    expect(requests.first["reasoning"]).to include("effort" => "low")
    follow_up = requests.find { |body| body["input"].any? { |item| item["type"] == "function_call_output" } }
    expect(follow_up["input"]).to include(include("type" => "reasoning", "encrypted_content" => a_kind_of(String)))
  end
end
# rubocop:enable RSpec/DescribeClass
