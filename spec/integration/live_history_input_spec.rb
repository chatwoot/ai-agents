# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"

RSpec.describe "Live LLM history input", :live_llm do
  include LiveLLMHelper

  let(:model) { live_model }

  before do
    configure_live_llm(model: model)
  end

  # Chatwoot passes the current user message both as input and as the last history entry.
  it "sends the current user message once when history already ends with it" do
    agent = Agents::Agent.new(
      name: "Assistant",
      instructions: "Answer with only the requested word.",
      model: model,
      temperature: 0
    )
    question = "What is my name?"
    history = [
      { role: :user, content: "My name is Ada." },
      { role: :assistant, content: "Nice to meet you, Ada.", agent_name: "Assistant" },
      { role: :user, content: question }
    ]

    result = Agents::Runner.with_agents(agent).run(
      question, context: { conversation_history: history }, headers: { "X-Agents-Smoke" => "history-input" }
    )

    expect(result.error).to be_nil
    expect(result.output.to_s).to match(/ada/i)
    expect(a_request(:post, "https://openrouter.ai/api/v1/chat/completions").with do |request|
      messages = JSON.parse(request.body)["messages"]
      user_contents = messages.filter_map { |msg| msg["content"] if msg["role"] == "user" }
      request.headers["X-Agents-Smoke"] == "history-input" && user_contents == ["My name is Ada.", question]
    end).to have_been_made.once
  end
end
