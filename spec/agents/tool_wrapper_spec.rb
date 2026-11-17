# frozen_string_literal: true

require_relative "../../lib/agents"

RSpec.describe Agents::ToolWrapper do
  let(:tool) { Agents::Tool.new }
  let(:callback_manager) { instance_double(Agents::CallbackManager) }
  let(:context_wrapper) { instance_double(Agents::RunContext, callback_manager: callback_manager, context: {}) }
  let(:tool_wrapper) { described_class.new(tool, context_wrapper) }

  before do
    allow(callback_manager).to receive(:emit_tool_start)
    allow(callback_manager).to receive(:emit_tool_complete)
  end

  describe "#initialize" do
    it "stores the tool and context wrapper" do
      expect(tool_wrapper.instance_variable_get(:@tool)).to eq(tool)
      expect(tool_wrapper.instance_variable_get(:@context_wrapper)).to eq(context_wrapper)
    end

    it "copies tool name and description" do
      wrapper = described_class.new(tool, context_wrapper)

      expect(wrapper.instance_variable_get(:@name)).to eq(tool.name)
      expect(wrapper.instance_variable_get(:@description)).to eq(tool.description)
    end
  end

  describe "#call" do
    it "does not execute later tool calls after a handoff" do
      allow(context_wrapper).to receive(:context).and_return(pending_handoff: { target_agent: "Support" })
      allow(tool).to receive(:execute)

      expect(tool_wrapper.call(city: "NYC")).to eq("Skipped after agent handoff")
      expect(tool).not_to have_received(:execute)
    end

    it "creates tool context and calls tool with injected context" do
      tool_context = instance_double(Agents::ToolContext)
      args = { "city" => "NYC", "country" => "USA" }

      allow(Agents::ToolContext).to receive(:new).with(run_context: context_wrapper).and_return(tool_context)
      allow(tool).to receive(:execute).with(tool_context, city: "NYC", country: "USA").and_return("result")

      result = tool_wrapper.call(**args)

      expect(result).to eq("result")
      expect(Agents::ToolContext).to have_received(:new).with(run_context: context_wrapper)
      expect(tool).to have_received(:execute).with(tool_context, city: "NYC", country: "USA")
    end

    it "transforms string keys to symbols" do
      tool_context = instance_double(Agents::ToolContext)
      args = { "string_key" => "value" }

      allow(Agents::ToolContext).to receive(:new).and_return(tool_context)
      allow(tool).to receive(:execute).with(tool_context, string_key: "value")

      tool_wrapper.call(**args)

      expect(tool).to have_received(:execute).with(tool_context, string_key: "value")
    end

    it "emits tool_complete with error message when tool execution fails" do
      tool_context = instance_double(Agents::ToolContext)
      args = { "city" => "NYC" }
      error_message = "Network timeout"

      allow(Agents::ToolContext).to receive(:new).with(run_context: context_wrapper).and_return(tool_context)
      allow(tool).to receive(:execute).with(tool_context, city: "NYC").and_raise(StandardError, error_message)

      expect { tool_wrapper.call(**args) }.to raise_error(StandardError, error_message)

      expect(callback_manager).to have_received(:emit_tool_start).with(tool.name, args, context_wrapper)
      expect(callback_manager).to have_received(:emit_tool_complete).with(
        tool.name, "ERROR: #{error_message}", context_wrapper, an_instance_of(StandardError)
      )
    end
  end

  describe "#name" do
    it "returns cached name when available" do
      allow(tool).to receive(:name).and_return("original_name")
      wrapper = described_class.new(tool, context_wrapper)
      wrapper.instance_variable_set(:@name, "cached_name")

      expect(wrapper.name).to eq("cached_name")
    end

    it "delegates to tool when no cached name" do
      allow(tool).to receive(:name).and_return("tool_name")

      expect(tool_wrapper.name).to eq("tool_name")
    end
  end

  describe "#description" do
    it "returns cached description when available" do
      allow(tool).to receive(:description).and_return("original_desc")
      wrapper = described_class.new(tool, context_wrapper)
      wrapper.instance_variable_set(:@description, "cached_desc")

      expect(wrapper.description).to eq("cached_desc")
    end

    it "delegates to tool when no cached description" do
      allow(tool).to receive(:description).and_return("tool description")

      expect(tool_wrapper.description).to eq("tool description")
    end
  end

  describe "#parameters_schema" do
    it "delegates to tool" do
      params = { city: { type: "string" } }
      allow(tool).to receive(:parameters_schema).and_return(params)

      expect(tool_wrapper.parameters_schema).to eq(params)
    end
  end

  describe "RubyLLM tool interface" do
    it "has no namespace, so the qualified name is the tool name" do
      allow(tool).to receive(:name).and_return("weather_tool")

      expect(tool_wrapper.namespace).to be_nil
      expect(tool_wrapper.qualified_name).to eq("weather_tool")
    end

    it "is never deferred" do
      expect(described_class.deferred?).to be false
      expect(tool_wrapper.deferred?).to be false
    end

    context "with a tool that decides approval and scheduling itself" do
      let(:tool) do
        Class.new(Agents::Tool) do
          def requires_approval?(tool_call = nil)
            tool_call.arguments["amount"] > 100
          end

          def exclusive?
            true
          end

          def max_run_time
            30
          end
        end.new
      end

      it "forwards the tool call RubyLLM passes to requires_approval?" do
        large = RubyLLM::ToolCall.new(id: "call_1", name: "refund", arguments: { "amount" => 500 })
        small = RubyLLM::ToolCall.new(id: "call_2", name: "refund", arguments: { "amount" => 5 })

        expect(tool_wrapper.requires_approval?(large)).to be true
        expect(tool_wrapper.requires_approval?(small)).to be false
      end

      it "delegates exclusive? and max_run_time to the tool" do
        expect(tool_wrapper.exclusive?).to be true
        expect(tool_wrapper.max_run_time).to eq(30)
      end
    end
  end

  describe "#to_s" do
    it "returns the tool name" do
      allow(tool).to receive(:name).and_return("weather_tool")

      expect(tool_wrapper.to_s).to eq("weather_tool")
    end
  end
end
