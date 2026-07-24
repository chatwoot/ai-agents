# frozen_string_literal: true

require "webmock/rspec"
require_relative "../../lib/agents"

RSpec.describe Agents::Runner do
  include OpenAITestHelper

  let(:custom_tool_class) do
    Class.new(Agents::HandoffTool) do
      description "Delegate with structured operational context"
      param :reason, type: "string", desc: "Why this handoff is needed"
      param :summary, type: "string", desc: "Context for the destination agent"

      def perform(tool_context, reason:, summary:)
        prepare_handoff(tool_context, reason: reason, metadata: { summary: summary })
      end
    end
  end
  let(:target) do
    Agents::Agent.new(name: "Specialist", instructions: "Handle specialist requests", model: "gpt-4o")
  end
  let(:hook_calls) { [] }
  let(:callback_calls) { [] }
  let(:source) do
    Agents::Agent.new(name: "Triage", instructions: "Route requests", model: "gpt-4o").tap do |agent|
      agent.register_handoff(
        target,
        tool_factory: ->(target_agent:, **) { custom_tool_class.new(target_agent) },
        on_handoff: lambda do |context, handoff_info|
          hook_calls << [context, handoff_info]
          context.context[:received_handoff_metadata] = handoff_info[:metadata]
        end
      )
    end
  end
  let(:callbacks) do
    {
      agent_handoff: [lambda do |from, to, reason, context, metadata|
        callback_calls << [from, to, reason, context, metadata]
      end]
    }
  end
  let(:dynamic_prompt_contexts) { [] }
  let(:dynamic_target) do
    Agents::Agent.new(
      name: "DynamicSpecialist",
      instructions: lambda do |context|
        dynamic_prompt_contexts << context.context[:received_handoff_metadata]
        "Handle specialist requests"
      end,
      model: "gpt-4o"
    )
  end
  let(:dynamic_source) do
    Agents::Agent.new(name: "Triage", instructions: "Route requests", model: "gpt-4o").tap do |agent|
      agent.register_handoff(
        dynamic_target,
        tool_factory: ->(target_agent:, **) { custom_tool_class.new(target_agent) },
        on_handoff: lambda do |context, handoff_info|
          context.context[:received_handoff_metadata] = handoff_info[:metadata]
        end
      )
    end
  end
  let(:failing_source) do
    Agents::Agent.new(name: "Triage", instructions: "Route requests", model: "gpt-4o").tap do |agent|
      agent.register_handoff(
        target,
        tool_factory: ->(target_agent:, **) { custom_tool_class.new(target_agent) },
        on_handoff: ->(*) { raise "handoff hook failed" }
      )
    end
  end
  let(:completed_agents) { [] }

  before do
    setup_openai_test_config
    disable_net_connect!
    stub_chat_sequence(
      {
        tool_calls: [{
          name: "handoff_to_specialist",
          arguments: { reason: "Needs specialist", summary: "Customer selected product 123" }
        }]
      },
      "Specialist response"
    )
  end

  after do
    allow_net_connect!
  end

  it "uses a custom handoff tool and exposes its reason and metadata to hooks and callbacks" do
    result = described_class.new.run(
      source,
      "Please help",
      registry: { "Triage" => source, "Specialist" => target },
      callbacks: callbacks
    )

    expect(result).to be_success
    expect(result.output).to eq("Specialist response")
    expect(result.context[:received_handoff_metadata]).to eq(summary: "Customer selected product 123")
    expect(hook_calls.one?).to be true
    expect(hook_calls.first.last).to include(
      target_agent: target,
      reason: "Needs specialist",
      metadata: { summary: "Customer selected product 123" }
    )
    expect(callback_calls).to contain_exactly(
      ["Triage", "Specialist", "Needs specialist", hook_calls.first.first,
       { summary: "Customer selected product 123" }]
    )
  end

  it "makes hook context available to the destination dynamic prompt" do
    stub_chat_sequence(
      {
        tool_calls: [{
          name: dynamic_source.all_tools.last.name,
          arguments: { reason: "Needs specialist", summary: "Customer selected product 123" }
        }]
      },
      "Specialist response"
    )

    result = described_class.new.run(
      dynamic_source,
      "Please help",
      registry: { "Triage" => dynamic_source, "DynamicSpecialist" => dynamic_target }
    )

    expect(result).to be_success
    expect(dynamic_prompt_contexts).to contain_exactly(summary: "Customer selected product 123")
  end

  it "fails without switching agents when the acceptance hook raises" do
    result = described_class.new.run(
      failing_source,
      "Please help",
      registry: { "Triage" => failing_source, "Specialist" => target },
      callbacks: {
        agent_complete: [lambda do |agent_name, _result, _error, _context|
          completed_agents << agent_name
        end]
      }
    )

    expect(result).to be_failed
    expect(result.error).to be_a(RuntimeError)
    expect(result.error.message).to eq("handoff hook failed")
    expect(result.context).not_to have_key(:pending_handoff)
    expect(completed_agents).to eq(["Triage"])
  end

  it "keeps legacy handoff callback arities compatible in the real runner flow" do
    three_argument_calls = []
    four_argument_calls = []

    result = described_class.new.run(
      source,
      "Please help",
      registry: { "Triage" => source, "Specialist" => target },
      callbacks: {
        agent_handoff: [
          ->(from, to, reason) { three_argument_calls << [from, to, reason] },
          lambda do |from, to, reason, context|
            four_argument_calls << [from, to, reason, context]
          end
        ]
      }
    )

    expect(result).to be_success
    expect(three_argument_calls).to eq([["Triage", "Specialist", "Needs specialist"]])
    expect(four_argument_calls).to contain_exactly(
      ["Triage", "Specialist", "Needs specialist", kind_of(Agents::RunContext)]
    )
  end
end
