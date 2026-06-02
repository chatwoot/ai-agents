# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Live agent handoff", :live_llm do
  include LiveLLMHelper

  let(:model) { live_model }

  before do
    configure_live_llm(model: ENV.fetch("OPENROUTER_MODEL", LiveLLMHelper::DEFAULT_LIVE_MODEL))
  end

  it "hands off to the target agent and continues the conversation" do
    specialist = Agents::Agent.new(
      name: "Specialist",
      instructions: "You only respond with the single word READY when a conversation is transferred to you.",
      model: model,
      temperature: 0
    )

    triage = Agents::Agent.new(
      name: "Triage",
      instructions: "Immediately call the handoff tool to transfer any request to Specialist. Do not answer yourself.",
      model: model,
      handoff_agents: [specialist],
      temperature: 0
    )

    runner = Agents::Runner.with_agents(triage, specialist)

    result = runner.run("Please assist me.")

    expect(result.error).to be_nil
    expect(result.context[:current_agent]).to eq("Specialist")
    expect(result.output).to match(/ready/i)
  end

  it "preserves restored assistant attribution after a later handoff" do
    specialist = Agents::Agent.new(
      name: "Specialist",
      instructions: "You only respond with the single word SPECIALIST_READY when a conversation is transferred to you.",
      model: model,
      temperature: 0
    )

    triage = Agents::Agent.new(
      name: "Triage",
      instructions: "If the user asks for the triage marker, respond only TRIAGE_MARKER and do not call tools. " \
                    "If the user asks to transfer, immediately call the handoff tool to Specialist.",
      model: model,
      handoff_agents: [specialist],
      temperature: 0
    )

    runner = Agents::Runner.with_agents(triage, specialist)
    triage_result = runner.run("Please provide the triage marker.")
    handoff_result = runner.run("Please transfer me now.", context: triage_result.context)

    history = handoff_result.context[:conversation_history]
    triage_message = history.find { |msg| msg[:role] == :assistant && msg[:content].to_s.match?(/TRIAGE_MARKER/i) }
    specialist_message = history.reverse.find { |msg| msg[:role] == :assistant }

    expect(triage_result.error).to be_nil
    expect(handoff_result.error).to be_nil
    expect(handoff_result.context[:current_agent]).to eq("Specialist")
    expect(triage_message).to include(agent_name: "Triage")
    expect(specialist_message).to include(agent_name: "Specialist")
  end
end
