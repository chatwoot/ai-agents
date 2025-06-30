# frozen_string_literal: true

require "webmock/rspec"
require_relative "../../lib/agents"

RSpec.describe Agents::AgentRunner do
  before do
    # Configure RubyLLM for testing
    RubyLLM.configure do |config|
      config.openai_api_key = "test"
    end

    WebMock.disable_net_connect!
  end

  after do
    WebMock.allow_net_connect!
  end

  let(:triage_agent) do
    instance_double(Agents::Agent,
                    name: "Triage Agent",
                    model: "gpt-4o",
                    tools: [],
                    handoff_agents: [],
                    get_system_prompt: "You are a triage agent")
  end

  let(:billing_agent) do
    instance_double(Agents::Agent,
                    name: "Billing Agent",
                    model: "gpt-4o",
                    tools: [],
                    handoff_agents: [],
                    get_system_prompt: "You are a billing agent")
  end

  let(:support_agent) do
    instance_double(Agents::Agent,
                    name: "Support Agent",
                    model: "gpt-4o",
                    tools: [],
                    handoff_agents: [],
                    get_system_prompt: "You are a support agent")
  end

  # Helper method for mock result
  let(:mock_result) do
    instance_double(Agents::RunResult,
                    output: "Test response",
                    context: {},
                    usage: {})
  end

  describe "#initialize" do
    context "with valid agents" do
      it "creates an agent runner with provided agents" do
        runner = described_class.new([triage_agent, billing_agent, support_agent])
        expect(runner).to be_a(described_class)
      end

      it "sets the first agent as the default" do
        runner = described_class.new([triage_agent, billing_agent, support_agent])

        # Access the default agent through the private method for testing
        default_agent = runner.send(:determine_conversation_agent, {})
        expect(default_agent).to eq(triage_agent)
      end

      it "builds registry from provided agents" do
        runner = described_class.new([triage_agent, billing_agent, support_agent])

        # Access the registry through the private method for testing
        registry = runner.instance_variable_get(:@registry)
        expect(registry).to include(
          "Triage Agent" => triage_agent,
          "Billing Agent" => billing_agent,
          "Support Agent" => support_agent
        )
      end

      it "freezes the agents array for thread safety" do
        agents = [triage_agent, billing_agent]
        runner = described_class.new(agents)

        frozen_agents = runner.instance_variable_get(:@agents)
        expect(frozen_agents).to be_frozen
      end

      it "freezes the registry for thread safety" do
        runner = described_class.new([triage_agent, billing_agent])

        registry = runner.instance_variable_get(:@registry)
        expect(registry).to be_frozen
      end
    end

    context "with invalid input" do
      it "raises ArgumentError when no agents provided" do
        expect { described_class.new([]) }.to raise_error(ArgumentError, "At least one agent must be provided")
      end

      it "raises ArgumentError when nil provided" do
        expect { described_class.new(nil) }.to raise_error(NoMethodError)
      end
    end
  end

  describe "#run" do
    let(:runner) { described_class.new([triage_agent, billing_agent, support_agent]) }
    let(:mock_runner_instance) { instance_double(Agents::Runner) }
    let(:mock_result) do
      instance_double(Agents::RunResult,
                      output: "Hello! How can I help?",
                      context: { conversation_history: [], current_agent: "Triage Agent" },
                      usage: {})
    end

    before do
      allow(Agents::Runner).to receive(:new).and_return(mock_runner_instance)
      allow(mock_runner_instance).to receive(:run).and_return(mock_result)
    end

    context "new conversation (empty context)" do
      it "uses the default agent (first in list)" do
        runner.run("Hello")

        expect(mock_runner_instance).to have_received(:run).with(
          triage_agent,
          "Hello",
          context: {},
          registry: hash_including("Triage Agent" => triage_agent),
          max_turns: Agents::Runner::DEFAULT_MAX_TURNS
        )
      end

      it "passes through max_turns parameter" do
        runner.run("Hello", max_turns: 5)

        expect(mock_runner_instance).to have_received(:run).with(
          triage_agent,
          "Hello",
          context: {},
          registry: anything,
          max_turns: 5
        )
      end
    end

    context "continuing conversation with history" do
      let(:context_with_history) do
        {
          conversation_history: [
            { role: :user, content: "I need billing help" },
            { role: :assistant, content: "I can help with billing", agent_name: "Billing Agent" },
            { role: :user, content: "What's my balance?" }
          ]
        }
      end

      it "determines agent from conversation history" do
        runner.run("More billing questions", context: context_with_history)

        expect(mock_runner_instance).to have_received(:run).with(
          billing_agent, # Should use Billing Agent based on history
          "More billing questions",
          context: context_with_history,
          registry: anything,
          max_turns: Agents::Runner::DEFAULT_MAX_TURNS
        )
      end
    end

    context "history with unknown agent" do
      let(:context_with_unknown_agent) do
        {
          conversation_history: [
            { role: :user, content: "Hello" },
            { role: :assistant, content: "Hi there", agent_name: "Unknown Agent" }
          ]
        }
      end

      it "falls back to default agent when agent not in registry" do
        runner.run("Continue conversation", context: context_with_unknown_agent)

        expect(mock_runner_instance).to have_received(:run).with(
          triage_agent, # Should fall back to default
          "Continue conversation",
          context: context_with_unknown_agent,
          registry: anything,
          max_turns: Agents::Runner::DEFAULT_MAX_TURNS
        )
      end
    end

    context "history without agent attribution" do
      let(:context_without_attribution) do
        {
          conversation_history: [
            { role: :user, content: "Hello" },
            { role: :assistant, content: "Hi there" } # No agent_name
          ]
        }
      end

      it "falls back to default agent when no agent attribution found" do
        runner.run("Continue", context: context_without_attribution)

        expect(mock_runner_instance).to have_received(:run).with(
          triage_agent, # Should fall back to default
          "Continue",
          context: context_without_attribution,
          registry: anything,
          max_turns: Agents::Runner::DEFAULT_MAX_TURNS
        )
      end
    end

    it "returns the result from the underlying runner" do
      result = runner.run("Test message")
      expect(result).to eq(mock_result)
    end
  end

  describe "private methods" do
    let(:runner) { described_class.new([triage_agent, billing_agent, support_agent]) }

    describe "#build_registry" do
      it "creates a hash mapping agent names to agents" do
        registry = runner.send(:build_registry, [triage_agent, billing_agent])

        expect(registry).to eq({
                                 "Triage Agent" => triage_agent,
                                 "Billing Agent" => billing_agent
                               })
      end

      it "handles duplicate agent names by using the last occurrence" do
        duplicate_agent = instance_double(Agents::Agent, name: "Triage Agent")
        registry = runner.send(:build_registry, [triage_agent, duplicate_agent])

        expect(registry["Triage Agent"]).to eq(duplicate_agent)
      end
    end

    describe "#determine_conversation_agent" do
      context "with empty context" do
        it "returns the default agent" do
          agent = runner.send(:determine_conversation_agent, {})
          expect(agent).to eq(triage_agent)
        end
      end

      context "with empty conversation history" do
        it "returns the default agent" do
          agent = runner.send(:determine_conversation_agent, { conversation_history: [] })
          expect(agent).to eq(triage_agent)
        end
      end

      context "with conversation history" do
        it "finds the last assistant message with agent attribution" do
          context = {
            conversation_history: [
              { role: :user, content: "Hello" },
              { role: :assistant, content: "Hi", agent_name: "Triage Agent" },
              { role: :user, content: "I need billing help" },
              { role: :assistant, content: "Sure thing", agent_name: "Billing Agent" },
              { role: :user, content: "What's my balance?" }
            ]
          }

          agent = runner.send(:determine_conversation_agent, context)
          expect(agent).to eq(billing_agent)
        end

        it "ignores assistant messages without agent attribution" do
          context = {
            conversation_history: [
              { role: :user, content: "Hello" },
              { role: :assistant, content: "Hi", agent_name: "Billing Agent" },
              { role: :assistant, content: "Additional info" }, # No agent_name
              { role: :user, content: "Continue" }
            ]
          }

          agent = runner.send(:determine_conversation_agent, context)
          expect(agent).to eq(billing_agent) # Should use the attributed message
        end

        it "falls back to default when agent not found in registry" do
          context = {
            conversation_history: [
              { role: :user, content: "Hello" },
              { role: :assistant, content: "Hi", agent_name: "Nonexistent Agent" }
            ]
          }

          agent = runner.send(:determine_conversation_agent, context)
          expect(agent).to eq(triage_agent)
        end

        it "handles missing agent_name gracefully" do
          context = {
            conversation_history: [
              { role: :user, content: "Hello" },
              { role: :assistant, content: "Hi", agent_name: nil }
            ]
          }

          agent = runner.send(:determine_conversation_agent, context)
          expect(agent).to eq(triage_agent)
        end
      end
    end
  end

  describe "thread safety" do
    let(:runner) { described_class.new([triage_agent, billing_agent, support_agent]) }

    it "can be safely used from multiple threads" do
      # Mock the underlying runner to avoid actual LLM calls
      allow(Agents::Runner).to receive(:new).and_return(
        instance_double(Agents::Runner, run: mock_result)
      )

      # Run multiple threads concurrently
      threads = 5.times.map do |i|
        Thread.new do
          runner.run("Message #{i}")
        end
      end

      # Wait for all threads to complete
      results = threads.map(&:value)

      # All threads should complete successfully
      expect(results).to all(eq(mock_result))
      expect(threads).to all(satisfy { |t| !t.alive? })
    end

    it "maintains immutable state across concurrent access" do
      original_registry = runner.instance_variable_get(:@registry)
      original_agents = runner.instance_variable_get(:@agents)

      # Simulate concurrent access
      threads = 3.times.map do
        Thread.new do
          # Access the private methods (simulating internal usage)
          runner.send(:determine_conversation_agent, {})
          runner.send(:build_registry, [triage_agent])
        end
      end

      threads.each(&:join)

      # State should remain unchanged
      expect(runner.instance_variable_get(:@registry)).to eq(original_registry)
      expect(runner.instance_variable_get(:@agents)).to eq(original_agents)
    end
  end

  describe "integration with Agents::Runner.with_agents" do
    it "is returned by the class method" do
      runner = Agents::Runner.with_agents(triage_agent, billing_agent)
      expect(runner).to be_a(described_class)
    end

    it "works with the factory method" do
      allow(Agents::Runner).to receive(:new).and_return(
        instance_double(Agents::Runner, run: mock_result)
      )

      runner = Agents::Runner.with_agents(triage_agent, billing_agent)
      result = runner.run("Test message")

      expect(result).to eq(mock_result)
    end
  end
end
