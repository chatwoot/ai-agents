# frozen_string_literal: true

require "spec_helper"

class AddNumbersTool < Agents::Tool
  param :a, type: "integer", desc: "First addend"
  param :b, type: "integer", desc: "Second addend"

  def name
    "add_numbers"
  end

  def description
    "Add two integers"
  end

  def perform(_tool_context, a:, b:)
    a + b
  end
end

RSpec.describe "Live LLM tool call", :live_llm do
  include LiveLLMHelper

  let(:model) { live_model }

  before do
    configure_live_llm(model: ENV.fetch("OPENAI_MODEL", LiveLLMHelper::DEFAULT_LIVE_MODEL))
  end

  it "invokes a simple tool and returns its result" do
    agent = Agents::Agent.new(
      name: "ToolUser",
      instructions: "Use the add_numbers tool to add 2 and 3. Call the tool exactly once. Return only the numeric result.",
      model: model,
      tools: [AddNumbersTool.new],
      temperature: 0
    )

    runner = Agents::Runner.with_agents(agent)

    result = runner.run("Add 2 and 3.")

    expect(result.error).to be_nil
    expect(result.output.to_s.strip).to include("5")
    expect(result.messages.any? { |msg| msg[:role] == :tool && msg[:content].to_s.include?("5") }).to be true
  end
end
