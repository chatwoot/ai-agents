# frozen_string_literal: true

require_relative "../../lib/agents"

RSpec.describe Agents::ToolWrapper do
  let(:tool) do
    instance_double(Agents::Tool,
                    name: "test_tool",
                    description: "A test tool",
                    parameters: { city: { type: "string", description: "City name" }, country: { type: "string", description: "Country name" } },
                    execute: "result",
                    perform: "result")
  end
  let(:context_wrapper) { instance_double(Agents::RunContext) }
  let(:tool_wrapper) { described_class.new(tool, context_wrapper) }

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
    it "creates tool context and calls tool with injected context" do
      tool_context = instance_double(Agents::ToolContext)
      args = { "city" => "NYC", "country" => "USA" }

      allow(Agents::ToolContext).to receive(:new).with(run_context: context_wrapper).and_return(tool_context)
      allow(tool).to receive(:perform).with(tool_context, city: "NYC", country: "USA").and_return("result")

      result = tool_wrapper.call(args)

      expect(result).to eq("result")
      expect(Agents::ToolContext).to have_received(:new).with(run_context: context_wrapper)
      expect(tool).to have_received(:perform).with(tool_context, city: "NYC", country: "USA")
    end

    it "transforms string keys to symbols" do
      tool_context = instance_double(Agents::ToolContext)
      args = { "city" => "NYC", "country" => "USA" }

      allow(Agents::ToolContext).to receive(:new).and_return(tool_context)
      allow(tool).to receive(:perform).with(tool_context, city: "NYC", country: "USA")

      tool_wrapper.call(args)

      expect(tool).to have_received(:perform).with(tool_context, city: "NYC", country: "USA")
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

  describe "#parameters" do
    it "delegates to tool" do
      params = { city: { type: "string" } }
      allow(tool).to receive(:parameters).and_return(params)

      expect(tool_wrapper.parameters).to eq(params)
    end
  end

  describe "#to_s" do
    it "returns the tool name" do
      allow(tool).to receive(:name).and_return("weather_tool")

      expect(tool_wrapper.to_s).to eq("weather_tool")
    end
  end
end
