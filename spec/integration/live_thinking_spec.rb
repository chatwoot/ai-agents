# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"

RSpec.describe "Live LLM thinking", :live_llm do
  include LiveLLMHelper

  let(:model) { ENV.fetch("OPENROUTER_REASONING_MODEL", "openai/gpt-5-nano") }

  before do
    configure_live_llm(model: model)
  end

  it "replays reasoning from a JSON-restored context on the next run" do
    agent = Agents::Agent.new(
      name: "Reasoner",
      instructions: "Answer with only the final number.",
      model: model,
      provider: live_provider,
      protocol: :responses,
      temperature: nil,
      thinking: { effort: :low }
    )
    runner = Agents::Runner.with_agents(agent)

    first = runner.run("What is 17 * 3?")
    restored_context = JSON.parse(first.context.to_json, symbolize_names: true)
    second = runner.run("Add 10 to your previous answer.", context: restored_context)

    expect(first.error).to be_nil
    expect(first.output.to_s).to include("51")
    expect(first.context[:conversation_history]).to include(
      hash_including(role: :assistant, thinking_signature: a_kind_of(String))
    )
    expect(second.error).to be_nil
    expect(second.output.to_s).to include("61")
    expect(a_request(:post, "https://openrouter.ai/api/v1/responses").with do |request|
      JSON.parse(request.body)["input"].any? { |item| item["type"] == "reasoning" && item["encrypted_content"] }
    end).to have_been_made.once
  end
end
