# frozen_string_literal: true

require "webmock/rspec"
require_relative "../../lib/agents"

RSpec.describe Agents::Runner do
  include OpenAITestHelper

  before do
    setup_openai_test_config
    disable_net_connect!
  end

  after do
    allow_net_connect!
  end

  let(:agent) do
    instance_double(Agents::Agent,
                    name: "TestAgent",
                    model: "gpt-4o",
                    tools: [],
                    handoff_agents: [],
                    temperature: 0.7,
                    response_schema: nil,
                    get_system_prompt: "You are a helpful assistant")
  end

  let(:handoff_agent) do
    instance_double(Agents::Agent,
                    name: "HandoffAgent",
                    model: "gpt-4o",
                    tools: [],
                    handoff_agents: [],
                    temperature: 0.7,
                    response_schema: nil,
                    get_system_prompt: "You are a specialist")
  end

  let(:test_tool) do
    instance_double(Agents::Tool,
                    name: "test_tool",
                    description: "A test tool",
                    parameters: {},
                    call: "tool result")
  end

  describe ".with_agents" do
    it "returns an AgentRunner instance" do
      result = described_class.with_agents(agent, handoff_agent)
      expect(result).to be_a(Agents::AgentRunner)
    end

    it "passes all agents to AgentRunner constructor" do
      allow(Agents::AgentRunner).to receive(:new).with([agent, handoff_agent])
      described_class.with_agents(agent, handoff_agent)
      expect(Agents::AgentRunner).to have_received(:new).with([agent, handoff_agent])
    end
  end

  describe "#run" do
    let(:runner) { described_class.new }

    context "when simple conversation without tools" do
      before do
        stub_simple_chat("Hello! How can I help you?")
      end

      it "completes simple conversation in single turn" do
        result = runner.run(agent, "Hello")

        expect(result).to be_a(Agents::RunResult)
        expect(result.output).to eq("Hello! How can I help you?")
        expect(result.success?).to be true
        expect(result.messages).to include(
          hash_including(role: :user, content: "Hello"),
          hash_including(role: :assistant, content: "Hello! How can I help you?")
        )
      end

      it "includes context in result" do
        result = runner.run(agent, "Hello", context: { user_id: 123 })

        expect(result.context).to include(user_id: 123)
        expect(result.context).to include(:conversation_history)
        expect(result.context).to include(turn_count: 1)
        expect(result.context).to include(:last_updated)
      end
    end

    context "with conversation history" do
      let(:context_with_history) do
        {
          conversation_history: [
            { role: :user, content: "What's 2+2?" },
            { role: :assistant, content: "2+2 equals 4." }
          ]
        }
      end

      before do
        stub_request(:post, "https://api.openai.com/v1/chat/completions")
          .to_return(
            status: 200,
            body: {
              id: "chatcmpl-456",
              object: "chat.completion",
              created: 1_677_652_288,
              model: "gpt-4o",
              choices: [{
                index: 0,
                message: {
                  role: "assistant",
                  content: "Yes, that's correct! Is there anything else?"
                },
                finish_reason: "stop"
              }],
              usage: { prompt_tokens: 25, completion_tokens: 12, total_tokens: 37 }
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "restores conversation history" do
        result = runner.run(agent, "Thanks for confirming", context: context_with_history)

        expect(result.success?).to be true
        expect(result.output).to eq("Yes, that's correct! Is there anything else?")
        expect(result.messages.length).to eq(4) # 2 from history + 2 new
      end

      context "with string roles in history" do
        let(:context_with_string_roles) do
          {
            conversation_history: [
              { role: "user", content: "What's 2+2?" },
              { role: "assistant", content: "2+2 equals 4." }
            ]
          }
        end

        it "handles string roles correctly" do
          result = runner.run(agent, "Thanks for confirming", context: context_with_string_roles)

          expect(result.success?).to be true
          expect(result.output).to eq("Yes, that's correct! Is there anything else?")
          expect(result.messages.length).to eq(4) # 2 from history + 2 new
        end
      end
    end

    context "when using current_agent from context" do
      let(:context_with_agent) { { current_agent: "HandoffAgent" } }

      before do
        stub_simple_chat("I'm the specialist agent")
      end

      it "stores current agent name in context" do
        registry = { "TestAgent" => agent, "HandoffAgent" => handoff_agent }
        allow(handoff_agent).to receive(:get_system_prompt)

        result = runner.run(agent, "Hello", context: context_with_agent, registry: registry)

        expect(result.success?).to be true
        expect(result.context[:current_agent]).to eq("TestAgent")
      end
    end

    context "when handoff occurs" do
      let(:agent_with_handoffs) do
        instance_double(Agents::Agent,
                        name: "TriageAgent",
                        model: "gpt-4o",
                        tools: [],
                        handoff_agents: [handoff_agent],
                        temperature: 0.7,
                        response_schema: nil,
                        get_system_prompt: "You route users to specialists")
      end

      let(:handoff_tool_instance) do
        instance_double(Agents::HandoffTool,
                        name: "handoff_to_handoffagent",
                        description: "Transfer to HandoffAgent",
                        parameters: {},
                        target_agent: handoff_agent,
                        execute: "Transferring to HandoffAgent")
      end

      before do
        allow(Agents::HandoffTool).to receive(:new).with(handoff_agent)
                                                   .and_return(handoff_tool_instance)

        # First request - triage agent decides to handoff, then specialist responds
        stub_chat_sequence(
          { tool_calls: [{ name: "handoff_to_handoffagent", arguments: "{}" }] },
          "Hello, I'm the specialist. How can I help?"
        )
      end

      it "switches to handoff agent and continues conversation" do
        registry = { "TriageAgent" => agent_with_handoffs, "HandoffAgent" => handoff_agent }
        result = runner.run(agent_with_handoffs, "I need specialist help", registry: registry)

        expect(result.success?).to be true
        expect(result.output).to eq("Hello, I'm the specialist. How can I help?")
        expect(result.context[:current_agent]).to eq("HandoffAgent")
      end
    end

    context "when max_turns is exceeded" do
      it "raises MaxTurnsExceeded and returns error result" do
        # Mock chat to always return tool_call? = true, causing infinite loop
        mock_chat = instance_double(Agents::Chat)
        mock_response = instance_double(RubyLLM::Message, tool_call?: true)

        allow(runner).to receive_messages(
          create_chat: mock_chat,
          restore_conversation_history: nil,
          save_conversation_state: nil
        )
        allow(mock_chat).to receive_messages(ask: mock_response, complete: mock_response)

        result = runner.run(agent, "Start infinite loop", max_turns: 2)

        expect(result.failed?).to be true
        expect(result.error).to be_a(Agents::Runner::MaxTurnsExceeded)
        expect(result.output).to include("Exceeded maximum turns: 2")
        expect(result.context).to be_a(Hash)
        expect(result.messages).to eq([])
      end
    end

    context "when standard error occurs" do
      it "handles errors gracefully and returns error result" do
        # Mock chat creation to raise an error
        allow(runner).to receive(:create_chat).and_raise(StandardError, "Test error")

        result = runner.run(agent, "Error test")

        expect(result.failed?).to be true
        expect(result.error).to be_a(StandardError)
        expect(result.error.message).to eq("Test error")
        expect(result.output).to be_nil
        expect(result.context).to be_a(Hash)
        expect(result.messages).to eq([])
      end
    end

    context "when respects custom max_turns limit" do
      it "respects custom max_turns limit" do
        # This will pass because we're not hitting the limit
        stub_request(:post, "https://api.openai.com/v1/chat/completions")
          .to_return(
            status: 200,
            body: {
              id: "chatcmpl-quick",
              object: "chat.completion",
              created: 1_677_652_288,
              model: "gpt-4o",
              choices: [{
                index: 0,
                message: { role: "assistant", content: "Done" },
                finish_reason: "stop"
              }],
              usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 }
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        result = runner.run(agent, "Quick response", max_turns: 1)

        expect(result.success?).to be true
        expect(result.output).to eq("Done")
      end
    end

    context "when using response_schema" do
      let(:schema) do
        {
          type: "object",
          properties: {
            answer: { type: "string" },
            confidence: { type: "number" }
          },
          required: %w[answer confidence]
        }
      end

      let(:agent_with_schema) do
        instance_double(Agents::Agent,
                        name: "StructuredAgent",
                        model: "gpt-4o",
                        tools: [],
                        handoff_agents: [],
                        temperature: 0.7,
                        response_schema: schema,
                        get_system_prompt: "You provide structured responses")
      end

      it "creates chat with agent's response_schema" do
        # Stub the OpenAI response with structured JSON
        stub_simple_chat('{"answer": "42", "confidence": 0.95}')

        # Spy on Chat creation to verify schema is passed
        chat_spy = nil
        allow(Agents::Chat).to receive(:new) do |**args|
          chat_spy = args
          instance_double(Agents::Chat,
                          with_instructions: nil,
                          with_tools: nil,
                          ask: instance_double(RubyLLM::Message,
                                               content: '{"answer": "42", "confidence": 0.95}',
                                               tool_call?: false,
                                               role: :assistant),
                          add_message: nil,
                          messages: [])
        end

        result = runner.run(
          agent_with_schema,
          "What is the answer?",
          context: {},
          registry: { "StructuredAgent" => agent_with_schema },
          max_turns: 1
        )

        expect(chat_spy).to include(response_schema: schema)
        expect(result.output).to eq('{"answer": "42", "confidence": 0.95}')
      end
    end
  end
end
