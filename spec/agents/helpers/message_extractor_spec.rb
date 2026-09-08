# frozen_string_literal: true

require "spec_helper"

RSpec.describe Agents::Helpers::MessageExtractor do
  let(:agent) { Agents::Agent.new(name: "Support") }

  def round_trip(message)
    chat = instance_double(RubyLLM::Chat, messages: [message])
    stored = described_class.extract_messages(chat, agent)
    described_class.restore_message(JSON.parse(stored.to_json).first)
  end

  it "preserves the native message format through JSON persistence" do
    message = RubyLLM::Message.new(
      role: :assistant, content: "Answer", model: "gpt-4o",
      thinking: "Reasoning", thinking_signature: "signature",
      raw_reasoning: { "id" => "reason_1" },
      raw_content: [{ "type" => "text", "text" => "Answer" }],
      citations: [{ type: "url", url: "https://example.com", title: "Source" }],
      finish_reason: :stop, input_tokens: 10, output_tokens: 5, cache_until_here: true
    )

    restored = round_trip(message)

    expect(restored.to_h).to eq(message.to_h)
    expect(described_class.attributed_agent_name_for(restored)).to eq("Support")
  end

  it "preserves attachment-only messages" do
    message = RubyLLM::Message.new(role: :user, content: nil,
                                   attachments: ["https://example.com/image.png"])

    expect(round_trip(message).attachments.first.to_h).to eq(message.attachments.first.to_h)
  end

  it "preserves tool-call IDs and provider signatures without symbolizing payloads" do
    message = RubyLLM::Message.new(
      role: :assistant, content: nil,
      tool_calls: { "call_1" => { name: "lookup", arguments: { "id" => 1 }, thought_signature: "signed" } }
    )

    restored = round_trip(message)

    expect(restored.tool_calls.keys).to eq(["call_1"])
    expect(restored.tool_calls["call_1"].to_h).to eq(message.tool_calls["call_1"].to_h)
  end

  it "preserves empty tool results" do
    message = RubyLLM::Message.new(role: :tool, content: nil, tool_call_id: "call_1")

    expect(round_trip(message).to_h).to eq(message.to_h)
  end

  it "keeps per-message author attribution across handoffs" do
    message = RubyLLM::Message.new(role: :assistant, content: "Routing")
    described_class.assign_agent_name(message, "Triage")

    expect(described_class.attributed_agent_name_for(round_trip(message))).to eq("Triage")
  end

  it "omits system instructions because the active agent supplies them" do
    message = RubyLLM::Message.new(role: :system, content: "Old instructions")
    chat = instance_double(RubyLLM::Chat, messages: [message])

    expect(described_class.extract_messages(chat, agent)).to be_empty
  end

  it "accepts legacy array-shaped tool calls" do
    message = described_class.restore_message(
      "role" => "assistant", "content" => nil, "agent_name" => "Triage",
      "tool_calls" => [{ "id" => "call_1", "name" => "lookup", "arguments" => { "id" => 1 } }]
    )

    expect(message.tool_calls["call_1"].arguments).to eq("id" => 1)
    expect(described_class.attributed_agent_name_for(message)).to eq("Triage")
  end

  it "converts legacy structured content to JSON text" do
    message = described_class.restore_message(role: :assistant, content: { answer: 42 })

    expect(message.parsed).to eq("answer" => 42)
  end

  it "converts legacy multimodal content to separate attachments" do
    message = described_class.restore_message(
      role: :user, content: [
        { type: "text", text: "Describe this" },
        { type: "image_url", image_url: { url: "https://example.com/image.png" } }
      ]
    )

    expect(message.content).to eq("Describe this")
    expect(message.attachments.size).to eq(1)
  end

  it "preserves legacy base64 images through repeated JSON round trips" do
    bytes = File.binread(File.expand_path("../../fixtures/dice_transparency.png", __dir__))
    data_url = "data:image/png;base64,#{Base64.strict_encode64(bytes)}"
    message = described_class.restore_message(
      role: :user, content: [{ type: "image_url", image_url: { url: data_url } }]
    )

    restored = round_trip(round_trip(message))

    expect(restored.attachments.first.content).to eq(bytes)
    expect(restored.attachments.first.mime_type).to eq("image/png")
  end

  it "ignores absent attribution" do
    message = RubyLLM::Message.new(role: :assistant, content: "Hello")
    described_class.assign_agent_name(message, nil)

    expect(described_class.attributed_agent_name_for(message)).to be_nil
    expect { described_class.assign_agent_name(nil, "Support") }.not_to raise_error
  end
end
