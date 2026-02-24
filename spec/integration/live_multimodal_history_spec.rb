# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Live LLM multimodal history", :live_llm do
  include LiveLLMHelper

  let(:model) { live_model }
  let(:image_url) do
    "https://raw.githubusercontent.com/chatwoot/ai-agents/main/spec/fixtures/dice_transparency.png"
  end
  let(:history) do
    [
      {
        role: :user,
        content: [
          { type: "text", text: "What do you see in this image?" },
          { type: "image_url", image_url: { url: image_url } }
        ]
      },
      {
        role: :assistant,
        # ensure that the context does not have the actual count
        content: "I can see a few dice on a transparent checkered background. " \
                 "This appears to be a PNG transparency demonstration image."
      }
    ]
  end

  before do
    configure_live_llm(model: ENV.fetch("OPENAI_MODEL", LiveLLMHelper::DEFAULT_LIVE_MODEL))
  end

  it "restores image content from conversation history and references it" do
    agent = Agents::Agent.new(
      name: "VisionAgent",
      instructions: "You are a helpful assistant that can analyze images.",
      model: model,
      temperature: 0
    )

    runner = Agents::Runner.with_agents(agent)
    result = runner.run(
      "Based on the image I shared earlier, how many dice were in it?",
      context: { conversation_history: history }
    )

    expect(result.error).to be_nil
    expect(result.output.to_s.downcase).to match(/four|4/)
  end
end
