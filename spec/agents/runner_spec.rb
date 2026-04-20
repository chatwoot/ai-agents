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
                    get_system_prompt: "You are a helpful assistant",
                    headers: {},
                    params: {},
                    input_guards: [],
                    output_guards: [])
  end

  let(:handoff_agent) do
    instance_double(Agents::Agent,
                    name: "HandoffAgent",
                    model: "gpt-4o",
                    tools: [],
                    handoff_agents: [],
                    temperature: 0.7,
                    response_schema: nil,
                    get_system_prompt: "You are a specialist",
                    headers: {},
                    params: {},
                    input_guards: [],
                    output_guards: [])
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

    context "with custom headers" do
      it "passes runtime headers to RubyLLM chat" do
        mock_chat = instance_double(RubyLLM::Chat)
        mock_response = instance_double(RubyLLM::Message, tool_call?: false, content: "Hello with headers",
                                                          input_tokens: 10, output_tokens: 5)
        headers = { "X-Test" => "value" }

        allow(RubyLLM::Chat).to receive(:new).and_return(mock_chat)
        allow(mock_chat).to receive(:add_message)
        allow(Agents::Helpers::MessageExtractor).to receive(:extract_messages).and_return([])
        allow(mock_chat).to receive_messages(with_instructions: mock_chat, with_temperature: mock_chat,
                                             with_tools: mock_chat, with_schema: mock_chat, with_model: mock_chat, ask: mock_response)

        expect(mock_chat).to receive(:with_headers).with("X-Test": "value").and_return(mock_chat)

        result = runner.run(agent, "Hello", headers: headers)

        expect(result.output).to eq("Hello with headers")
      end

      it "applies agent default headers when runtime headers are absent" do
        mock_chat = instance_double(RubyLLM::Chat)
        mock_response = instance_double(RubyLLM::Message, tool_call?: false, content: "Hello with agent headers",
                                                          input_tokens: 10, output_tokens: 5)

        allow(agent).to receive(:headers).and_return({ "X-Agent" => "agent-value" })
        allow(RubyLLM::Chat).to receive(:new).and_return(mock_chat)
        allow(mock_chat).to receive(:add_message)
        allow(Agents::Helpers::MessageExtractor).to receive(:extract_messages).and_return([])
        allow(mock_chat).to receive_messages(with_instructions: mock_chat, with_temperature: mock_chat,
                                             with_tools: mock_chat, with_schema: mock_chat, with_model: mock_chat, ask: mock_response)

        expect(mock_chat).to receive(:with_headers).with("X-Agent": "agent-value").and_return(mock_chat)

        result = runner.run(agent, "Hello")

        expect(result.output).to eq("Hello with agent headers")
      end

      it "merges headers giving runtime precedence over agent defaults" do
        mock_chat = instance_double(RubyLLM::Chat)
        mock_response = instance_double(RubyLLM::Message, tool_call?: false, content: "Hello with merged headers",
                                                          input_tokens: 10, output_tokens: 5)
        runtime_headers = {
          "X-Shared" => "runtime",
          "X-Runtime-Only" => "runtime-only"
        }

        allow(agent).to receive(:headers).and_return({ "X-Shared" => "agent", "X-Agent-Only" => "agent-only" })
        allow(RubyLLM::Chat).to receive(:new).and_return(mock_chat)
        allow(mock_chat).to receive(:add_message)
        allow(Agents::Helpers::MessageExtractor).to receive(:extract_messages).and_return([])
        allow(mock_chat).to receive_messages(with_instructions: mock_chat, with_temperature: mock_chat,
                                             with_tools: mock_chat, with_schema: mock_chat, with_model: mock_chat, ask: mock_response)

        expect(mock_chat).to receive(:with_headers).with(
          "X-Shared": "runtime",
          "X-Agent-Only": "agent-only",
          "X-Runtime-Only": "runtime-only"
        ).and_return(mock_chat)

        result = runner.run(agent, "Hello", headers: runtime_headers)

        expect(result.output).to eq("Hello with merged headers")
      end
    end

    context "with custom params" do
      it "passes runtime params to RubyLLM chat" do
        mock_chat = instance_double(RubyLLM::Chat)
        mock_response = instance_double(RubyLLM::Message, tool_call?: false, content: "Hello with params",
                                                          input_tokens: 10, output_tokens: 5)
        params = { service_tier: "default" }

        allow(RubyLLM::Chat).to receive(:new).and_return(mock_chat)
        allow(mock_chat).to receive(:add_message)
        allow(mock_chat).to receive(:with_params).and_return(mock_chat)
        allow(Agents::Helpers::MessageExtractor).to receive(:extract_messages).and_return([])
        allow(mock_chat).to receive_messages(with_instructions: mock_chat, with_temperature: mock_chat,
                                             with_tools: mock_chat, with_schema: mock_chat,
                                             with_model: mock_chat, ask: mock_response)

        result = runner.run(agent, "Hello", params: params)

        expect(result.output).to eq("Hello with params")
        expect(mock_chat).to have_received(:with_params).with(service_tier: "default")
      end

      it "applies agent default params when runtime params are absent" do
        mock_chat = instance_double(RubyLLM::Chat)
        mock_response = instance_double(RubyLLM::Message, tool_call?: false, content: "Hello with agent params",
                                                          input_tokens: 10, output_tokens: 5)

        allow(agent).to receive(:params).and_return({ service_tier: "flex" })
        allow(RubyLLM::Chat).to receive(:new).and_return(mock_chat)
        allow(mock_chat).to receive(:add_message)
        allow(mock_chat).to receive(:with_params).and_return(mock_chat)
        allow(Agents::Helpers::MessageExtractor).to receive(:extract_messages).and_return([])
        allow(mock_chat).to receive_messages(with_instructions: mock_chat, with_temperature: mock_chat,
                                             with_tools: mock_chat, with_schema: mock_chat,
                                             with_model: mock_chat, ask: mock_response)

        result = runner.run(agent, "Hello")

        expect(result.output).to eq("Hello with agent params")
        expect(mock_chat).to have_received(:with_params).with(service_tier: "flex")
      end

      it "merges params giving runtime precedence over agent defaults" do
        mock_chat = instance_double(RubyLLM::Chat)
        mock_response = instance_double(RubyLLM::Message, tool_call?: false, content: "Hello with merged params",
                                                          input_tokens: 10, output_tokens: 5)
        runtime_params = { service_tier: "default", max_tokens: 1000 }

        allow(agent).to receive(:params).and_return({ service_tier: "flex", top_p: 0.9 })
        allow(RubyLLM::Chat).to receive(:new).and_return(mock_chat)
        allow(mock_chat).to receive(:add_message)
        allow(mock_chat).to receive(:with_params).and_return(mock_chat)
        allow(Agents::Helpers::MessageExtractor).to receive(:extract_messages).and_return([])
        allow(mock_chat).to receive_messages(with_instructions: mock_chat, with_temperature: mock_chat,
                                             with_tools: mock_chat, with_schema: mock_chat,
                                             with_model: mock_chat, ask: mock_response)

        result = runner.run(agent, "Hello", params: runtime_params)

        expect(result.output).to eq("Hello with merged params")
        expect(mock_chat).to have_received(:with_params).with(
          service_tier: "default",
          top_p: 0.9,
          max_tokens: 1000
        )
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

    context "with multimodal content in history" do
      let(:multimodal_content) do
        [
          { type: "text", text: "Here is my error screenshot" },
          { type: "image_url", image_url: { url: "https://example.com/error.png" } }
        ]
      end

      let(:context_with_multimodal_history) do
        {
          conversation_history: [
            { role: :user, content: multimodal_content },
            { role: :assistant, content: "I can see a 500 error in your screenshot." }
          ]
        }
      end

      before do
        stub_request(:post, "https://api.openai.com/v1/chat/completions")
          .to_return(
            status: 200,
            body: {
              id: "chatcmpl-multimodal",
              object: "chat.completion",
              created: 1_677_652_288,
              model: "gpt-4o",
              choices: [{
                index: 0,
                message: {
                  role: "assistant",
                  content: "Looking at the screenshot again, I see the connection pool error."
                },
                finish_reason: "stop"
              }],
              usage: { prompt_tokens: 30, completion_tokens: 15, total_tokens: 45 }
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "restores multimodal messages with image attachments" do
        result = runner.run(agent, "Can you look at the top-right corner?", context: context_with_multimodal_history)

        expect(result.success?).to be true
        expect(result.messages.length).to eq(4) # 2 from history + 2 new
      end

      it "preserves image URLs in restored user messages" do
        runner_instance = Agents::Runner.new
        mock_chat = instance_double(RubyLLM::Chat)
        context_wrapper = Agents::RunContext.new(context_with_multimodal_history)

        messages_added = []
        allow(mock_chat).to receive(:add_message) { |msg| messages_added << msg }

        runner_instance.send(:restore_conversation_history, mock_chat, context_wrapper)

        user_msg = messages_added.find { |m| m.role == :user }
        expect(user_msg).not_to be_nil
        expect(user_msg.content).to be_a(RubyLLM::Content)
        expect(user_msg.content.text).to eq("Here is my error screenshot")
        expect(user_msg.content.attachments.first.source.to_s).to eq("https://example.com/error.png")
      end

      context "with string-keyed multimodal content" do
        let(:string_keyed_content) do
          [
            { "type" => "text", "text" => "Check this image" },
            { "type" => "image_url", "image_url" => { "url" => "https://example.com/img.png" } }
          ]
        end

        it "handles string keys in multimodal arrays" do
          runner_instance = Agents::Runner.new
          mock_chat = instance_double(RubyLLM::Chat)
          ctx = { conversation_history: [{ role: :user, content: string_keyed_content }] }
          context_wrapper = Agents::RunContext.new(ctx)

          messages_added = []
          allow(mock_chat).to receive(:add_message) { |msg| messages_added << msg }

          runner_instance.send(:restore_conversation_history, mock_chat, context_wrapper)

          user_msg = messages_added.first
          expect(user_msg.content).to be_a(RubyLLM::Content)
          expect(user_msg.content.text).to eq("Check this image")
          expect(user_msg.content.attachments.first.source.to_s).to eq("https://example.com/img.png")
        end
      end

      context "with text-only multimodal arrays" do
        it "handles arrays with no image parts as plain text" do
          runner_instance = Agents::Runner.new
          mock_chat = instance_double(RubyLLM::Chat)
          text_only_array = [{ type: "text", text: "Just text, no images" }]
          ctx = { conversation_history: [{ role: :user, content: text_only_array }] }
          context_wrapper = Agents::RunContext.new(ctx)

          messages_added = []
          allow(mock_chat).to receive(:add_message) { |msg| messages_added << msg }

          runner_instance.send(:restore_conversation_history, mock_chat, context_wrapper)

          user_msg = messages_added.first
          expect(user_msg.content.to_s).to eq("Just text, no images")
        end
      end
    end

    context "with tool message history" do
      let(:context_with_tool_history) do
        {
          conversation_history: [
            { role: :user, content: "What's the weather in SF?" },
            {
              role: :assistant,
              content: "Let me check that for you",
              tool_calls: [
                { id: "call_123", name: "get_weather", arguments: { location: "SF" } }
              ]
            },
            { role: :tool, content: "72°F, Sunny", tool_call_id: "call_123" },
            { role: :assistant, content: "It's 72°F and sunny in SF!" }
          ]
        }
      end

      before do
        stub_request(:post, "https://api.openai.com/v1/chat/completions")
          .to_return(
            status: 200,
            body: {
              id: "chatcmpl-789",
              object: "chat.completion",
              created: 1_677_652_300,
              model: "gpt-4o",
              choices: [{
                index: 0,
                message: {
                  role: "assistant",
                  content: "Great weather for a walk!"
                },
                finish_reason: "stop"
              }],
              usage: { prompt_tokens: 50, completion_tokens: 10, total_tokens: 60 }
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "restores tool messages with tool_call_id" do
        result = runner.run(agent, "Should I go outside?", context: context_with_tool_history)

        expect(result.success?).to be true
        expect(result.output).to eq("Great weather for a walk!")
        # Should have all history messages + new user message + new assistant message
        expect(result.messages.length).to eq(6)
      end

      it "preserves conversation flow with tool execution context" do
        result = runner.run(agent, "Thanks!", context: context_with_tool_history)

        expect(result.success?).to be true
        # Verify we have the complete conversation history restored
        # NOTE: tool_calls arrays are not restored on assistant messages (see runner.rb NOTE)
        # What matters is: assistant content + tool result messages preserve the conversation flow
        expect(result.messages.length).to be >= 4 # At minimum, history messages are preserved

        # Verify assistant message content is preserved
        assistant_msg = result.messages.find do |msg|
          msg[:role] == :assistant && msg[:content].include?("Let me check")
        end
        expect(assistant_msg).not_to be_nil
      end

      it "restores tool result messages with tool_call_id" do
        result = runner.run(agent, "Thanks!", context: context_with_tool_history)

        expect(result.success?).to be true
        # Verify tool result message is preserved
        tool_message = result.messages.find { |msg| msg[:role] == :tool }
        expect(tool_message).not_to be_nil
        expect(tool_message[:content]).to eq("72°F, Sunny")
        expect(tool_message[:tool_call_id]).to eq("call_123")
      end

      context "with multiple tool calls in single turn" do
        let(:context_with_multiple_tools) do
          {
            conversation_history: [
              { role: :user, content: "Compare weather in SF and LA" },
              {
                role: :assistant,
                content: "Let me check both cities",
                tool_calls: [
                  { id: "call_1", name: "get_weather", arguments: { location: "SF" } },
                  { id: "call_2", name: "get_weather", arguments: { location: "LA" } }
                ]
              },
              { role: :tool, content: "72°F, Sunny", tool_call_id: "call_1" },
              { role: :tool, content: "85°F, Partly cloudy", tool_call_id: "call_2" },
              { role: :assistant, content: "SF is 72°F and sunny, LA is 85°F and partly cloudy" }
            ]
          }
        end

        before do
          stub_request(:post, "https://api.openai.com/v1/chat/completions")
            .to_return(
              status: 200,
              body: {
                id: "chatcmpl-multi",
                object: "chat.completion",
                created: 1_677_652_400,
                model: "gpt-4o",
                choices: [{
                  index: 0,
                  message: {
                    role: "assistant",
                    content: "SF has better weather today!"
                  },
                  finish_reason: "stop"
                }],
                usage: { prompt_tokens: 80, completion_tokens: 8, total_tokens: 88 }
              }.to_json,
              headers: { "Content-Type" => "application/json" }
            )
        end

        it "restores all tool messages in correct order" do
          result = runner.run(agent, "Which is better?", context: context_with_multiple_tools)

          expect(result.success?).to be true
          expect(result.output).to eq("SF has better weather today!")

          tool_messages = result.messages.select { |msg| msg[:role] == :tool }
          expect(tool_messages.length).to eq(2)
          expect(tool_messages[0][:tool_call_id]).to eq("call_1")
          expect(tool_messages[1][:tool_call_id]).to eq("call_2")
        end
      end

      context "with tool_calls stored using string keys" do
        let(:context_with_string_tool_calls) do
          {
            conversation_history: [
              { role: :user, content: "What's the weather in SF?" },
              {
                role: :assistant,
                content: "Let me check that for you",
                tool_calls: [
                  { "id" => "call_123", "name" => "get_weather", "arguments" => { "location" => "SF" } }
                ]
              },
              { role: :tool, content: "72°F, Sunny", tool_call_id: "call_123" },
              { role: :assistant, content: "It's 72°F and sunny in SF!" }
            ]
          }
        end

        before do
          stub_simple_chat("Clear skies ahead!")
        end

        it "restores tool_calls and tool results when tool_call ids are string keyed" do
          result = runner.run(agent, "Anything else?", context: context_with_string_tool_calls)

          expect(result.success?).to be true

          tool_message = result.messages.find { |msg| msg[:role] == :tool }
          expect(tool_message).not_to be_nil
          expect(tool_message[:tool_call_id]).to eq("call_123")

          assistant_with_tools = result.messages.find do |msg|
            msg[:role] == :assistant && msg[:tool_calls]&.any?
          end
          expect(assistant_with_tools).not_to be_nil
          expect(assistant_with_tools[:tool_calls].first[:id]).to eq("call_123")
        end
      end

      context "with empty tool result" do
        let(:context_with_empty_tool_result) do
          {
            conversation_history: [
              { role: :user, content: "Check status" },
              {
                role: :assistant,
                content: "Checking...",
                tool_calls: [{ id: "call_empty", name: "check_status", arguments: {} }]
              },
              { role: :tool, content: "", tool_call_id: "call_empty" },
              { role: :assistant, content: "Status check complete, no data returned" }
            ]
          }
        end

        before do
          stub_simple_chat("OK")
        end

        it "restores tool messages even with empty content" do
          result = runner.run(agent, "Got it", context: context_with_empty_tool_result)

          expect(result.success?).to be true
          # Empty tool results should still be restored as they're part of the conversation
          tool_message = result.messages.find { |msg| msg[:role] == :tool }
          expect(tool_message).not_to be_nil
          expect(tool_message[:content]).to eq("")
          expect(tool_message[:tool_call_id]).to eq("call_empty")
        end
      end

      context "with invalid tool message (missing tool_call_id)" do
        let(:context_with_invalid_tool) do
          {
            conversation_history: [
              { role: :user, content: "Hello" },
              { role: :tool, content: "Invalid tool result", tool_call_id: nil },
              { role: :assistant, content: "Hi there" }
            ]
          }
        end

        before do
          stub_simple_chat("How can I help?")
          # Set up a mock logger
          logger = instance_double(Logger)
          allow(logger).to receive(:warn)
          Agents.logger = logger
        end

        after do
          Agents.logger = nil
        end

        it "skips tool messages without tool_call_id" do
          result = runner.run(agent, "I need help", context: context_with_invalid_tool)

          expect(result.success?).to be true
          # Invalid tool message should be skipped
          tool_messages = result.messages.select { |msg| msg[:role] == :tool }
          expect(tool_messages).to be_empty
          expect(Agents.logger).to have_received(:warn)
            .with("Skipping tool message without tool_call_id in conversation history")
        end
      end

      context "with hash content in tool result" do
        let(:context_with_hash_content) do
          {
            conversation_history: [
              { role: :user, content: "Get data" },
              {
                role: :assistant,
                content: "Fetching...",
                tool_calls: [{ id: "call_hash", name: "get_data", arguments: {} }]
              },
              {
                role: :tool,
                content: { status: "success", data: { temperature: 72 } },
                tool_call_id: "call_hash"
              },
              { role: :assistant, content: "Data retrieved successfully" }
            ]
          }
        end

        before do
          stub_simple_chat("Anything else?")
        end

        it "restores tool messages with hash content" do
          result = runner.run(agent, "No, thanks", context: context_with_hash_content)

          expect(result.success?).to be true
          tool_message = result.messages.find { |msg| msg[:role] == :tool }
          expect(tool_message).not_to be_nil
          expect(tool_message[:content]).to eq({ status: "success", data: { temperature: 72 } })
          expect(tool_message[:tool_call_id]).to eq("call_hash")
        end
      end

      context "with assistant tool calls that have empty content" do
        let(:context_with_tool_only_assistant) do
          {
            conversation_history: [
              { role: :user, content: "Trigger a tool" },
              {
                role: :assistant,
                content: "",
                tool_calls: [{ id: "call_blank", name: "do_something", arguments: {} }]
              },
              { role: :tool, content: "Done", tool_call_id: "call_blank" }
            ]
          }
        end

        before do
          stub_simple_chat("All set")
        end

        it "restores assistant tool call messages even without text" do
          result = runner.run(agent, "Thanks", context: context_with_tool_only_assistant)

          expect(result.success?).to be true

          assistant_with_tools = result.messages.find do |msg|
            msg[:role] == :assistant && msg[:tool_calls]&.any?
          end

          expect(assistant_with_tools).not_to be_nil
          expect(assistant_with_tools[:content]).to eq("")
          expect(assistant_with_tools[:tool_calls].first[:id]).to eq("call_blank")
        end
      end

      it "restores tool_calls on assistant messages" do
        # As of commit 1cfe99e, tool_calls ARE restored on assistant messages
        # because OpenAI/Anthropic APIs require tool result messages to be
        # preceded by assistant messages with matching tool_calls.
        # See runner.rb:310-321 for implementation.

        # Track what gets added to the chat during restoration
        restored_messages = []
        mock_chat = instance_double(RubyLLM::Chat)

        allow(RubyLLM::Chat).to receive(:new).and_return(mock_chat)
        allow(mock_chat).to receive(:add_message) do |msg|
          restored_messages << {
            role: msg.role,
            content: msg.content.to_s,
            tool_calls: msg.tool_calls,
            tool_call: msg.respond_to?(:tool_call?) ? msg.tool_call? : nil
          }
        end

        # Mock other required methods
        allow(mock_chat).to receive_messages(
          with_instructions: mock_chat,
          with_temperature: mock_chat,
          with_tools: mock_chat,
          with_schema: mock_chat,
          with_model: mock_chat,
          messages: [],
          ask: instance_double(RubyLLM::Message,
                               tool_call?: false,
                               content: "Confirmed",
                               is_a?: false)
        )

        # Run with history containing tool_calls
        runner.run(agent, "Verify", context: context_with_tool_history)

        # Find the restored assistant message that had tool_calls in history
        assistant_msg = restored_messages.find do |m|
          m[:role] == :assistant && m[:content].include?("Let me check")
        end

        # Verify expected behavior: both content AND tool_calls are restored
        expect(assistant_msg).not_to be_nil
        expect(assistant_msg[:content]).to eq("Let me check that for you")
        expect(assistant_msg[:tool_calls]).to be_a(Hash)
        expect(assistant_msg[:tool_calls]).not_to be_empty
        expect(assistant_msg[:tool_calls]["call_123"]).not_to be_nil
        expect(assistant_msg[:tool_calls]["call_123"]).to be_a(RubyLLM::ToolCall)
        expect(assistant_msg[:tool_calls]["call_123"].id).to eq("call_123")

        # Tool messages should still be restored normally
        tool_msg = restored_messages.find { |m| m[:role] == :tool }
        expect(tool_msg).not_to be_nil
        expect(tool_msg[:content]).to eq("72°F, Sunny")
      end

      context "with tool_calls missing ids" do
        let(:context_with_missing_tool_call_id) do
          {
            conversation_history: [
              { role: :user, content: "Use a tool" },
              {
                role: :assistant,
                content: "Calling tool",
                tool_calls: [{ name: "add_numbers", arguments: { a: 1, b: 2 } }]
              },
              { role: :tool, content: "3", tool_call_id: "call_missing" }
            ]
          }
        end

        before do
          stub_simple_chat("OK")
        end

        it "skips tool_calls without ids and ignores unmatched tool messages" do
          result = runner.run(agent, "Continue", context: context_with_missing_tool_call_id)

          expect(result.success?).to be true
          assistant_msg = result.messages.find { |msg| msg[:role] == :assistant }
          expect(assistant_msg[:tool_calls]).to be_nil

          tool_messages = result.messages.select { |msg| msg[:role] == :tool }
          expect(tool_messages).to be_empty
        end
      end

      context "with out-of-order tool history" do
        let(:context_with_out_of_order_tool_history) do
          {
            conversation_history: [
              { role: :user, content: "Check status" },
              { role: :tool, content: "OK", tool_call_id: "call_early" },
              {
                role: :assistant,
                content: "Calling tool now",
                tool_calls: [{ id: "call_early", name: "check_status", arguments: {} }]
              }
            ]
          }
        end

        before do
          stub_simple_chat("Done")
        end

        it "skips tool results that appear before their tool_calls" do
          # Current behavior: drop out-of-order tool results because we only accept tool messages
          # after the matching assistant tool_call has been restored. Alternative options:
          # 1) pre-scan history to collect tool_call_ids, or
          # 2) buffer tool results until their tool_call appears later.
          result = runner.run(agent, "Continue", context: context_with_out_of_order_tool_history)

          expect(result.success?).to be true
          tool_messages = result.messages.select { |msg| msg[:role] == :tool }
          expect(tool_messages).to be_empty
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
                        get_system_prompt: "You route users to specialists",
                        headers: {},
                        params: {},
                        input_guards: [],
                        output_guards: [])
      end

      before do
        # First request - triage agent decides to handoff
        # After handoff, the specialist agent responds
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

      it "returns error when handoff to unregistered agent is attempted" do
        # Only register the triage agent, not the handoff target
        registry = { "TriageAgent" => agent_with_handoffs }

        # Mock only the first tool call that triggers handoff
        stub_request(:post, "https://api.openai.com/v1/chat/completions")
          .to_return(
            status: 200,
            body: {
              id: "chatcmpl-handoff",
              object: "chat.completion",
              created: 1_677_652_288,
              model: "gpt-4o",
              choices: [{
                index: 0,
                message: {
                  role: "assistant",
                  content: nil,
                  tool_calls: [{
                    id: "call_handoff",
                    type: "function",
                    function: {
                      name: "handoff_to_handoffagent",
                      arguments: "{}"
                    }
                  }]
                },
                finish_reason: "tool_calls"
              }],
              usage: { prompt_tokens: 20, completion_tokens: 5, total_tokens: 25 }
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        result = runner.run(agent_with_handoffs, "I need specialist help", registry: registry)

        expect(result.failed?).to be true
        expect(result.error).to be_a(Agents::Runner::AgentNotFoundError)
        expect(result.error.message).to eq("Handoff failed: Agent 'HandoffAgent' not found in registry")
        expect(result.output).to be_nil
        expect(result.context[:current_agent]).to eq("TriageAgent")
        expect(result.context[:pending_handoff]).to be_nil # Should clear pending handoff
      end
    end

    context "when max_turns is exceeded" do
      it "raises MaxTurnsExceeded and returns error result" do
        # Mock chat to always return tool_call? = true, causing infinite loop
        mock_chat = instance_double(RubyLLM::Chat)
        mock_response = instance_double(RubyLLM::Message, tool_call?: true,
                                                          input_tokens: 10, output_tokens: 5)

        allow(RubyLLM::Chat).to receive(:new).and_return(mock_chat)
        allow(runner).to receive_messages(
          configure_chat_for_agent: mock_chat,
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
        allow(RubyLLM::Chat).to receive(:new).and_raise(StandardError, "Test error")

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

    context "when halt response occurs without handoff" do
      it "returns halt content as final response" do
        # Mock chat to return a halt without pending_handoff
        mock_chat = instance_double(RubyLLM::Chat)
        mock_halt = instance_double(RubyLLM::Tool::Halt, content: "Processing complete", is_a?: true)

        allow(mock_halt).to receive(:is_a?).with(RubyLLM::Tool::Halt).and_return(true)
        allow(RubyLLM::Chat).to receive(:new).and_return(mock_chat)
        allow(runner).to receive_messages(
          configure_chat_for_agent: mock_chat,
          restore_conversation_history: nil,
          save_conversation_state: nil
        )
        allow(mock_chat).to receive(:ask).and_return(mock_halt)

        result = runner.run(agent, "Test halt")

        expect(result.success?).to be true
        expect(result.output).to eq("Processing complete")
        expect(result.context).to be_a(Hash)
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
                        get_system_prompt: "You provide structured responses",
                        headers: {},
                        params: {},
                        input_guards: [],
                        output_guards: [])
      end

      it "includes response_schema in API request" do
        # Expect the request to include response_format with our schema
        stub_request(:post, "https://api.openai.com/v1/chat/completions")
          .with(body: hash_including({
                                       "response_format" => {
                                         "type" => "json_schema",
                                         "json_schema" => {
                                           "name" => "response",
                                           "schema" => schema,
                                           "strict" => true
                                         }
                                       }
                                     }))
          .to_return(status: 200, body: {
            id: "test", object: "chat.completion", created: Time.now.to_i, model: "gpt-4o",
            choices: [{ index: 0, message: { role: "assistant", content: "any response" }, finish_reason: "stop" }],
            usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 }
          }.to_json, headers: { "Content-Type" => "application/json" })

        runner.run(
          agent_with_schema,
          "What is the answer?",
          context: {},
          registry: { "StructuredAgent" => agent_with_schema },
          max_turns: 1
        )

        # If we get here without WebMock raising an error, the request included the schema
      end

      context "when conversation history contains Hash content from structured output" do
        it "processes messages with Hash content without raising strip errors" do
          # Set up conversation history with Hash content
          context_with_hash_content = {
            conversation_history: [
              { role: :user, content: "What is 2+2?" },
              { role: :assistant, content: { "answer" => "4", "confidence" => 1.0 }, agent_name: "StructuredAgent" }
            ],
            current_agent: "StructuredAgent"
          }

          # Stub simple OpenAI response for the new message
          stub_simple_chat('{"answer": "6", "confidence": 0.9}')

          # This should work without throwing NoMethodError on Hash#strip
          result = runner.run(
            agent_with_schema,
            "What about 3+3?",
            context: context_with_hash_content,
            registry: { "StructuredAgent" => agent_with_schema },
            max_turns: 1
          )

          expect(result.success?).to be true
          expect(result.output).to eq({ "answer" => "6", "confidence" => 0.9 })
        end
      end
    end

    context "when agent has regular tools" do
      let(:agent_with_tools) do
        instance_double(Agents::Agent,
                        name: "ToolAgent",
                        model: "gpt-4o",
                        tools: [test_tool],
                        handoff_agents: [],
                        temperature: 0.7,
                        response_schema: nil,
                        get_system_prompt: "You are an agent with tools",
                        headers: {},
                        params: {},
                        input_guards: [],
                        output_guards: [])
      end

      it "wraps regular tools in ToolWrapper" do
        # Spy on ToolWrapper constructor
        allow(Agents::ToolWrapper).to receive(:new).and_call_original

        # Stub a simple response that doesn't use tools
        stub_simple_chat("I have tools available")

        runner.run(
          agent_with_tools,
          "Hello",
          context: {},
          registry: { "ToolAgent" => agent_with_tools },
          max_turns: 1
        )

        # Verify ToolWrapper was called with the regular tool
        expect(Agents::ToolWrapper).to have_received(:new).with(test_tool, anything)
      end
    end

    context "lifecycle callbacks" do
      let(:runner) { described_class.new }
      let(:callbacks_called) { [] }
      let(:callbacks) do
        {
          run_start: [proc { |agent, input, ctx| callbacks_called << [:run_start, agent, input, ctx.class.name] }],
          run_complete: [proc { |agent, result, ctx|
            callbacks_called << [:run_complete, agent, result.class.name, ctx.class.name]
          }],
          agent_complete: [proc { |agent, result, error, ctx|
            callbacks_called << [:agent_complete, agent, result&.class&.name, error&.class&.name, ctx.class.name]
          }],
          agent_thinking: [proc { |agent, input| callbacks_called << [:agent_thinking, agent, input] }],
          tool_start: [proc { |tool, args| callbacks_called << [:tool_start, tool, args] }],
          tool_complete: [proc { |tool, result| callbacks_called << [:tool_complete, tool, result] }],
          agent_handoff: [proc { |from, to, reason| callbacks_called << [:agent_handoff, from, to, reason] }]
        }
      end

      it "emits run_start and run_complete for successful execution" do
        stub_simple_chat("Hello!")

        result = runner.run(agent, "Test", callbacks: callbacks)

        expect(result.success?).to be true
        expect(callbacks_called).to include(
          [:run_start, "TestAgent", "Test", "Agents::RunContext"]
        )
        expect(callbacks_called).to include(
          [:run_complete, "TestAgent", "Agents::RunResult", "Agents::RunContext"]
        )
      end

      it "emits agent_complete with nil error for successful execution" do
        stub_simple_chat("Success")

        runner.run(agent, "Test", callbacks: callbacks)

        agent_complete_call = callbacks_called.find { |c| c[0] == :agent_complete }
        expect(agent_complete_call).not_to be_nil
        expect(agent_complete_call[1]).to eq("TestAgent")
        expect(agent_complete_call[2]).to eq("Agents::RunResult")
        expect(agent_complete_call[3]).to be_nil # No error
        expect(agent_complete_call[4]).to eq("Agents::RunContext")
      end

      it "emits callbacks in correct order" do
        stub_simple_chat("Response")

        runner.run(agent, "Test", callbacks: callbacks)

        # Extract just the callback types in order
        callback_types = callbacks_called.map(&:first)

        # Verify run_start comes first
        expect(callback_types.first).to eq(:run_start)

        # Verify run_complete and agent_complete come last
        expect(callback_types[-2..]).to contain_exactly(:agent_complete, :run_complete)
      end

      it "emits agent_complete and run_complete with error on failure" do
        allow(RubyLLM::Chat).to receive(:new).and_raise(StandardError, "Test error")

        result = runner.run(agent, "Test", callbacks: callbacks)

        expect(result.failed?).to be true

        # Check agent_complete was called with error
        agent_complete_call = callbacks_called.find { |c| c[0] == :agent_complete }
        expect(agent_complete_call).not_to be_nil
        expect(agent_complete_call[3]).to eq("StandardError")

        # Check run_complete was still called
        run_complete_call = callbacks_called.find { |c| c[0] == :run_complete }
        expect(run_complete_call).not_to be_nil
      end

      it "emits agent_complete before handoff" do
        agent_with_handoff = instance_double(Agents::Agent,
                                             name: "TriageAgent",
                                             model: "gpt-4o",
                                             tools: [],
                                             handoff_agents: [handoff_agent],
                                             temperature: 0.7,
                                             response_schema: nil,
                                             get_system_prompt: "You route users",
                                             headers: {},
                                             params: {},
                                             input_guards: [],
                                             output_guards: [])

        stub_chat_sequence(
          { tool_calls: [{ name: "handoff_to_handoffagent", arguments: "{}" }] },
          "Specialist here"
        )

        registry = { "TriageAgent" => agent_with_handoff, "HandoffAgent" => handoff_agent }
        runner.run(agent_with_handoff, "Help", registry: registry, callbacks: callbacks)

        callback_types = callbacks_called.map(&:first)

        # Find indices
        agent_complete_idx = callback_types.index(:agent_complete)
        handoff_idx = callback_types.index(:agent_handoff)

        # agent_complete should come before agent_handoff
        expect(agent_complete_idx).not_to be_nil
        expect(handoff_idx).not_to be_nil
        expect(agent_complete_idx).to be < handoff_idx
      end

      it "emits agent_complete and run_complete with error when handoff target not found" do
        agent_with_handoff = instance_double(Agents::Agent,
                                             name: "TriageAgent",
                                             model: "gpt-4o",
                                             tools: [],
                                             handoff_agents: [handoff_agent],
                                             temperature: 0.7,
                                             response_schema: nil,
                                             get_system_prompt: "You route users",
                                             headers: {},
                                             params: {},
                                             input_guards: [],
                                             output_guards: [])

        stub_request(:post, "https://api.openai.com/v1/chat/completions")
          .to_return(
            status: 200,
            body: {
              id: "chatcmpl-handoff",
              object: "chat.completion",
              created: 1_677_652_288,
              model: "gpt-4o",
              choices: [{
                index: 0,
                message: {
                  role: "assistant",
                  content: nil,
                  tool_calls: [{
                    id: "call_handoff",
                    type: "function",
                    function: { name: "handoff_to_handoffagent", arguments: "{}" }
                  }]
                },
                finish_reason: "tool_calls"
              }],
              usage: { prompt_tokens: 20, completion_tokens: 5, total_tokens: 25 }
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        # Registry only has TriageAgent, not HandoffAgent
        registry = { "TriageAgent" => agent_with_handoff }
        result = runner.run(agent_with_handoff, "Help", registry: registry, callbacks: callbacks)

        expect(result.failed?).to be true
        expect(result.error).to be_a(Agents::Runner::AgentNotFoundError)

        # Check agent_complete was called with error
        agent_complete_call = callbacks_called.find { |c| c[0] == :agent_complete }
        expect(agent_complete_call).not_to be_nil
        expect(agent_complete_call[1]).to eq("TriageAgent")
        expect(agent_complete_call[3]).to eq("Agents::Runner::AgentNotFoundError")

        # Check run_complete was called
        run_complete_call = callbacks_called.find { |c| c[0] == :run_complete }
        expect(run_complete_call).not_to be_nil
        expect(run_complete_call[1]).to eq("TriageAgent")
      end
    end

    context "with input guards" do
      let(:rewriting_guard) do
        guard_class = Class.new(Agents::Guard) do
          guard_name "uppercaser"

          def call(content, _context)
            Agents::GuardResult.rewrite(content.upcase, message: "uppercased")
          end
        end
        guard_class.new
      end

      let(:guarded_agent) do
        instance_double(Agents::Agent,
                        name: "GuardedAgent",
                        model: "gpt-4o",
                        tools: [],
                        handoff_agents: [],
                        temperature: 0.7,
                        response_schema: nil,
                        get_system_prompt: "You are a guarded assistant",
                        headers: {},
                        params: {},
                        input_guards: [rewriting_guard],
                        output_guards: [])
      end

      it "sends rewritten input to the LLM" do
        stub_simple_chat("I received your message")

        result = runner.run(guarded_agent, "hello")

        expect(result.success?).to be true
        user_message = result.messages.find { |m| m[:role] == :user }
        expect(user_message[:content]).to eq("HELLO")
      end

      it "rewritten input defeats stale dedup from conversation history" do
        context_with_history = {
          conversation_history: [
            { role: :user, content: "hello" }
          ],
          current_agent: "GuardedAgent"
        }

        stub_simple_chat("Got your updated message")

        result = runner.run(guarded_agent, "hello", context: context_with_history)

        expect(result.success?).to be true
        user_messages = result.messages.select { |m| m[:role] == :user }
        expect(user_messages.last[:content]).to eq("HELLO")
      end
    end

    context "with output guards" do
      let(:redacting_guard) do
        guard_class = Class.new(Agents::Guard) do
          guard_name "redactor"

          def call(content, _context)
            redacted = content.gsub(/\d{3}-\d{2}-\d{4}/, "[REDACTED]")
            Agents::GuardResult.rewrite(redacted, message: "PII redacted") if redacted != content
          end
        end
        guard_class.new
      end

      let(:output_guarded_agent) do
        instance_double(Agents::Agent,
                        name: "OutputGuardedAgent",
                        model: "gpt-4o",
                        tools: [],
                        handoff_agents: [],
                        temperature: 0.7,
                        response_schema: nil,
                        get_system_prompt: "You are a guarded assistant",
                        headers: {},
                        params: {},
                        input_guards: [],
                        output_guards: [redacting_guard])
      end

      it "rewrites output before returning" do
        stub_simple_chat("Your SSN is 123-45-6789")

        result = runner.run(output_guarded_agent, "What is my SSN?")

        expect(result.success?).to be true
        expect(result.output).to eq("Your SSN is [REDACTED]")
      end

      it "passes output through unchanged when guard returns nil" do
        stub_simple_chat("No PII here")

        result = runner.run(output_guarded_agent, "Hello")

        expect(result.success?).to be true
        expect(result.output).to eq("No PII here")
      end
    end

    context "with output guards on structured output" do
      let(:schema) do
        {
          type: "object",
          properties: {
            answer: { type: "string" },
            ssn: { type: "string" }
          },
          required: %w[answer ssn]
        }
      end

      let(:json_redacting_guard) do
        guard_class = Class.new(Agents::Guard) do
          guard_name "json_redactor"

          def call(content, _context)
            redacted = content.gsub(/\d{3}-\d{2}-\d{4}/, "[REDACTED]")
            Agents::GuardResult.rewrite(redacted, message: "PII redacted") if redacted != content
          end
        end
        guard_class.new
      end

      let(:tripwire_guard) do
        guard_class = Class.new(Agents::Guard) do
          guard_name "json_blocker"

          def call(content, _context)
            Agents::GuardResult.tripwire(message: "blocked structured output") if content.include?("secret")
          end
        end
        guard_class.new
      end

      let(:passing_guard) do
        guard_class = Class.new(Agents::Guard) do
          guard_name "noop_guard"

          def call(_content, _context)
            nil
          end
        end
        guard_class.new
      end

      let(:structured_guarded_agent) do
        instance_double(Agents::Agent,
                        name: "StructuredGuardedAgent",
                        model: "gpt-4o",
                        tools: [],
                        handoff_agents: [],
                        temperature: 0.7,
                        response_schema: schema,
                        get_system_prompt: "You provide structured responses",
                        headers: {},
                        params: {},
                        input_guards: [],
                        output_guards: [json_redacting_guard])
      end

      it "redacts values inside structured output" do
        stub_simple_chat('{"answer": "here you go", "ssn": "123-45-6789"}')

        result = runner.run(structured_guarded_agent, "What is my SSN?")

        expect(result.success?).to be true
        expect(result.output).to be_a(Hash)
        expect(result.output["ssn"]).to eq("[REDACTED]")
        expect(result.output["answer"]).to eq("here you go")
      end

      it "tripwires on structured output" do
        tripwire_agent = instance_double(Agents::Agent,
                                         name: "TripwireStructuredAgent",
                                         model: "gpt-4o",
                                         tools: [],
                                         handoff_agents: [],
                                         temperature: 0.7,
                                         response_schema: schema,
                                         get_system_prompt: "You provide structured responses",
                                         headers: {},
                                         params: {},
                                         input_guards: [],
                                         output_guards: [tripwire_guard])

        stub_simple_chat('{"answer": "secret data", "ssn": "000-00-0000"}')

        result = runner.run(tripwire_agent, "Give me the secret")

        expect(result.tripwired?).to be true
        expect(result.guardrail_tripwire[:guard_name]).to eq("json_blocker")
      end

      it "preserves Hash type when guard passes" do
        pass_agent = instance_double(Agents::Agent,
                                     name: "PassStructuredAgent",
                                     model: "gpt-4o",
                                     tools: [],
                                     handoff_agents: [],
                                     temperature: 0.7,
                                     response_schema: schema,
                                     get_system_prompt: "You provide structured responses",
                                     headers: {},
                                     params: {},
                                     input_guards: [],
                                     output_guards: [passing_guard])

        stub_simple_chat('{"answer": "clean", "ssn": "none"}')

        result = runner.run(pass_agent, "Hello")

        expect(result.success?).to be true
        expect(result.output).to be_a(Hash)
        expect(result.output["answer"]).to eq("clean")
      end
    end

    context "with output guard that corrupts structured JSON" do
      it "returns a failed RunResult with JSON::ParserError" do
        corrupting_guard = Class.new(Agents::Guard) do
          guard_name "corruptor"

          def call(content, _context)
            Agents::GuardResult.rewrite(content[0..5], message: "truncated")
          end
        end.new

        schema = { type: "object", properties: { answer: { type: "string" } }, required: ["answer"] }
        corrupt_agent = instance_double(Agents::Agent,
                                        name: "CorruptAgent",
                                        model: "gpt-4o",
                                        tools: [],
                                        handoff_agents: [],
                                        temperature: 0.7,
                                        response_schema: schema,
                                        get_system_prompt: "You provide structured responses",
                                        headers: {},
                                        params: {},
                                        input_guards: [],
                                        output_guards: [corrupting_guard])

        stub_simple_chat('{"answer": "hello world"}')

        result = runner.run(corrupt_agent, "Hello")

        expect(result.failed?).to be true
        expect(result.error).to be_a(JSON::ParserError)
      end
    end

    context "with input guard tripwire" do
      let(:input_tripwire_guard) do
        guard_class = Class.new(Agents::Guard) do
          guard_name "input_blocker"

          def call(content, _context)
            Agents::GuardResult.tripwire(message: "banned input", metadata: { pattern: "evil" }) if content.include?("evil")
          end
        end
        guard_class.new
      end

      let(:input_tripwire_agent) do
        instance_double(Agents::Agent,
                        name: "InputTripwireAgent",
                        model: "gpt-4o",
                        tools: [],
                        handoff_agents: [],
                        temperature: 0.7,
                        response_schema: nil,
                        get_system_prompt: "You are guarded",
                        headers: {},
                        params: {},
                        input_guards: [input_tripwire_guard],
                        output_guards: [])
      end

      it "returns a tripwired RunResult with metadata" do
        stub_simple_chat("should not reach here")

        result = runner.run(input_tripwire_agent, "do something evil")

        expect(result.tripwired?).to be true
        expect(result.success?).to be false
        expect(result.output).to be_nil
        expect(result.guardrail_tripwire[:guard_name]).to eq("input_blocker")
        expect(result.guardrail_tripwire[:message]).to eq("banned input")
        expect(result.guardrail_tripwire[:metadata]).to eq({ pattern: "evil" })
      end

      it "emits agent_complete and run_complete callbacks on tripwire" do
        stub_simple_chat("should not reach here")

        callbacks_called = []
        callbacks = {
          run_start: [],
          run_complete: [proc { |*args| callbacks_called << [:run_complete, *args] }],
          agent_complete: [proc { |*args| callbacks_called << [:agent_complete, *args] }],
          agent_thinking: [],
          tool_start: [],
          tool_complete: [],
          agent_handoff: [],
          llm_call_complete: [],
          chat_created: [],
          guard_triggered: [proc { |*args| callbacks_called << [:guard_triggered, *args] }]
        }

        runner.run(input_tripwire_agent, "do something evil", callbacks: callbacks)

        guard_event = callbacks_called.find { |c| c[0] == :guard_triggered }
        expect(guard_event).not_to be_nil
        expect(guard_event[1]).to eq("input_blocker")

        complete_event = callbacks_called.find { |c| c[0] == :agent_complete }
        expect(complete_event).not_to be_nil

        run_event = callbacks_called.find { |c| c[0] == :run_complete }
        expect(run_event).not_to be_nil
      end
    end

    context "with guards across handoffs" do
      let(:pii_redactor) do
        guard_class = Class.new(Agents::Guard) do
          guard_name "pii_redactor"

          def call(content, _context)
            redacted = content.gsub(/\d{3}-\d{2}-\d{4}/, "[REDACTED]")
            Agents::GuardResult.rewrite(redacted, message: "PII redacted") if redacted != content
          end
        end
        guard_class.new
      end

      let(:specialist_tripwire) do
        guard_class = Class.new(Agents::Guard) do
          guard_name "specialist_blocker"

          def call(content, _context)
            Agents::GuardResult.tripwire(message: "blocked") if content.include?("specialist")
          end
        end
        guard_class.new
      end

      let(:uppercasing_guard) do
        guard_class = Class.new(Agents::Guard) do
          guard_name "uppercaser"

          def call(content, _context)
            Agents::GuardResult.rewrite(content.upcase, message: "uppercased")
          end
        end
        guard_class.new
      end

      it "applies agent B's output guards after handoff" do
        specialist = instance_double(Agents::Agent,
                                     name: "HandoffAgent",
                                     model: "gpt-4o",
                                     tools: [],
                                     handoff_agents: [],
                                     temperature: 0.7,
                                     response_schema: nil,
                                     get_system_prompt: "You are a specialist",
                                     headers: {},
                                     params: {},
                                     input_guards: [],
                                     output_guards: [pii_redactor])

        triage = instance_double(Agents::Agent,
                                 name: "TriageAgent",
                                 model: "gpt-4o",
                                 tools: [],
                                 handoff_agents: [specialist],
                                 temperature: 0.7,
                                 response_schema: nil,
                                 get_system_prompt: "You route users",
                                 headers: {},
                                 params: {},
                                 input_guards: [],
                                 output_guards: [])

        stub_chat_sequence(
          { tool_calls: [{ name: "handoff_to_handoffagent", arguments: "{}" }] },
          "Your SSN is 123-45-6789"
        )

        registry = { "TriageAgent" => triage, "HandoffAgent" => specialist }
        result = runner.run(triage, "What is my SSN?", registry: registry)

        expect(result.success?).to be true
        expect(result.output).to eq("Your SSN is [REDACTED]")
        expect(result.context[:current_agent]).to eq("HandoffAgent")
      end

      it "does NOT apply agent A's output guards after handoff" do
        triage_with_tripwire = instance_double(Agents::Agent,
                                               name: "TriageAgent",
                                               model: "gpt-4o",
                                               tools: [],
                                               handoff_agents: [handoff_agent],
                                               temperature: 0.7,
                                               response_schema: nil,
                                               get_system_prompt: "You route users",
                                               headers: {},
                                               params: {},
                                               input_guards: [],
                                               output_guards: [specialist_tripwire])

        stub_chat_sequence(
          { tool_calls: [{ name: "handoff_to_handoffagent", arguments: "{}" }] },
          "I'm the specialist, how can I help?"
        )

        registry = { "TriageAgent" => triage_with_tripwire, "HandoffAgent" => handoff_agent }
        result = runner.run(triage_with_tripwire, "Help me", registry: registry)

        expect(result.success?).to be true
        expect(result.output).to eq("I'm the specialist, how can I help?")
        expect(result.tripwired?).to be false
      end

      it "applies agent A's input guards before handoff occurs" do
        triage_with_input_guard = instance_double(Agents::Agent,
                                                  name: "TriageAgent",
                                                  model: "gpt-4o",
                                                  tools: [],
                                                  handoff_agents: [handoff_agent],
                                                  temperature: 0.7,
                                                  response_schema: nil,
                                                  get_system_prompt: "You route users",
                                                  headers: {},
                                                  params: {},
                                                  input_guards: [uppercasing_guard],
                                                  output_guards: [])

        stub_chat_sequence(
          { tool_calls: [{ name: "handoff_to_handoffagent", arguments: "{}" }] },
          "Specialist here to help"
        )

        registry = { "TriageAgent" => triage_with_input_guard, "HandoffAgent" => handoff_agent }
        result = runner.run(triage_with_input_guard, "help me", registry: registry)

        expect(result.success?).to be true
        # The user message should be the uppercased version from agent A's input guard
        user_message = result.messages.find { |m| m[:role] == :user }
        expect(user_message[:content]).to eq("HELP ME")
      end
    end

    context "with guards on handoff target agent" do
      let(:target_tripwire_guard) do
        guard_class = Class.new(Agents::Guard) do
          guard_name "target_input_blocker"

          def call(content, _context)
            Agents::GuardResult.tripwire(message: "blocked by target") if content.include?("blocked")
          end
        end
        guard_class.new
      end

      it "runs Agent B's input guards after handoff" do
        specialist = instance_double(Agents::Agent,
                                     name: "HandoffAgent",
                                     model: "gpt-4o",
                                     tools: [],
                                     handoff_agents: [],
                                     temperature: 0.7,
                                     response_schema: nil,
                                     get_system_prompt: "You are a specialist",
                                     headers: {},
                                     params: {},
                                     input_guards: [target_tripwire_guard],
                                     output_guards: [])

        triage = instance_double(Agents::Agent,
                                 name: "TriageAgent",
                                 model: "gpt-4o",
                                 tools: [],
                                 handoff_agents: [specialist],
                                 temperature: 0.7,
                                 response_schema: nil,
                                 get_system_prompt: "You route users",
                                 headers: {},
                                 params: {},
                                 input_guards: [],
                                 output_guards: [])

        stub_chat_sequence(
          { tool_calls: [{ name: "handoff_to_handoffagent", arguments: "{}" }] },
          "Specialist here to help"
        )

        registry = { "TriageAgent" => triage, "HandoffAgent" => specialist }
        result = runner.run(triage, "this should be blocked", registry: registry)

        expect(result.tripwired?).to be true
        expect(result.guardrail_tripwire[:guard_name]).to eq("target_input_blocker")
      end
    end

    context "with output guards on halt response" do
      let(:halt_redacting_guard) do
        guard_class = Class.new(Agents::Guard) do
          guard_name "halt_redactor"

          def call(content, _context)
            redacted = content.gsub(/\d{3}-\d{2}-\d{4}/, "[REDACTED]")
            Agents::GuardResult.rewrite(redacted, message: "PII redacted") if redacted != content
          end
        end
        guard_class.new
      end

      it "runs output guards on halt content before returning" do
        halt_guarded_agent = instance_double(Agents::Agent,
                                             name: "HaltGuardedAgent",
                                             model: "gpt-4o",
                                             tools: [],
                                             handoff_agents: [],
                                             temperature: 0.7,
                                             response_schema: nil,
                                             get_system_prompt: "You are guarded",
                                             headers: {},
                                             params: {},
                                             input_guards: [],
                                             output_guards: [halt_redacting_guard])

        mock_chat = instance_double(RubyLLM::Chat)
        mock_halt = instance_double(RubyLLM::Tool::Halt, content: "Your SSN is 123-45-6789")

        allow(mock_halt).to receive(:is_a?).with(RubyLLM::Tool::Halt).and_return(true)
        allow(RubyLLM::Chat).to receive(:new).and_return(mock_chat)
        allow(runner).to receive_messages(
          configure_chat_for_agent: mock_chat,
          restore_conversation_history: nil,
          save_conversation_state: nil
        )
        allow(mock_chat).to receive(:ask).and_return(mock_halt)

        result = runner.run(halt_guarded_agent, "What is my SSN?")

        expect(result.success?).to be true
        expect(result.output).to eq("Your SSN is [REDACTED]")
      end
    end

    context "with output guards on Array structured output" do
      let(:array_redacting_guard) do
        guard_class = Class.new(Agents::Guard) do
          guard_name "array_redactor"

          def call(content, _context)
            redacted = content.gsub(/\d{3}-\d{2}-\d{4}/, "[REDACTED]")
            Agents::GuardResult.rewrite(redacted, message: "PII redacted") if redacted != content
          end
        end
        guard_class.new
      end

      it "redacts values inside Array structured output and preserves Array type" do
        schema = {
          type: "array",
          items: { type: "object", properties: { ssn: { type: "string" } } }
        }
        array_agent = instance_double(Agents::Agent,
                                      name: "ArrayAgent",
                                      model: "gpt-4o",
                                      tools: [],
                                      handoff_agents: [],
                                      temperature: 0.7,
                                      response_schema: schema,
                                      get_system_prompt: "You provide arrays",
                                      headers: {},
                                      params: {},
                                      input_guards: [],
                                      output_guards: [array_redacting_guard])

        stub_simple_chat('[{"ssn":"123-45-6789"},{"ssn":"987-65-4321"}]')

        result = runner.run(array_agent, "List SSNs")

        expect(result.success?).to be true
        expect(result.output).to be_a(Array)
        expect(result.output[0]["ssn"]).to eq("[REDACTED]")
        expect(result.output[1]["ssn"]).to eq("[REDACTED]")
      end
    end

    context "without guards" do
      it "dedup still works when input matches history" do
        context_with_history = {
          conversation_history: [
            { role: :user, content: "hello" },
            { role: :assistant, content: "Hi there" }
          ],
          current_agent: "TestAgent"
        }

        stub_simple_chat("Continued response")

        result = runner.run(agent, "hello", context: context_with_history)

        expect(result.success?).to be true
      end
    end
  end
end
