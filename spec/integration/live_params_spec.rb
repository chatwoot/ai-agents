# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Live params passthrough", :live_llm do
  include LiveLLMHelper

  let(:model) { live_model }

  before do
    configure_live_llm(model: ENV.fetch("OPENAI_MODEL", LiveLLMHelper::DEFAULT_LIVE_MODEL))
  end

  context "with runtime params" do
    it "truncates output when max_completion_tokens is very low" do
      agent = Agents::Agent.new(
        name: "ParamsAgent",
        instructions: "Write a long essay about the history of computing.",
        model: model,
        temperature: 0
      )

      runner = Agents::Runner.with_agents(agent)

      result = runner.run("Write at least 500 words.", params: { max_completion_tokens: 5 })

      expect(result.error).to be_nil
      expect(result.output.to_s.split.length).to be < 20
    end
  end

  context "with agent-level params" do
    it "truncates output when agent has max_completion_tokens set" do
      agent = Agents::Agent.new(
        name: "AgentParamsAgent",
        instructions: "Write a long essay about the history of computing.",
        model: model,
        temperature: 0,
        params: { max_completion_tokens: 5 }
      )

      runner = Agents::Runner.with_agents(agent)

      result = runner.run("Write at least 500 words.")

      expect(result.error).to be_nil
      expect(result.output.to_s.split.length).to be < 20
    end
  end

  context "with merged params" do
    it "runtime params override agent defaults" do
      agent = Agents::Agent.new(
        name: "MergedParamsAgent",
        instructions: "Always respond with the single word PONG and nothing else.",
        model: model,
        temperature: 0,
        params: { max_completion_tokens: 1 }
      )

      runner = Agents::Runner.with_agents(agent)

      # Override with generous limit — should get the full PONG response
      result = runner.run("Reply with PONG only.", params: { max_completion_tokens: 50 })

      expect(result.error).to be_nil
      expect(result.output.to_s).to match(/\bpong\b/i)
    end
  end
end
