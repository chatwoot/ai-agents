# frozen_string_literal: true

RSpec.describe Agents::ToolWrapper do
  let(:context) { Agents::RunContext.new({ state: { customer: "Alice" } }) }
  let(:tool_class) do
    Class.new(Agents::Tool) do
      description "Greets a customer"
      parameter :greeting, description: "Greeting"

      def perform(tool_context, greeting:)
        "#{greeting} #{tool_context.state[:customer]}"
      end
    end
  end
  let(:tool) { tool_class.new }
  let(:wrapper) { described_class.new(tool, context) }

  it "injects state without passing invocation metadata to the tool" do
    call = RubyLLM::ToolCall.new(id: "call_1", name: tool.name, arguments: { greeting: "Hi" })

    expect(wrapper.call(greeting: "Hi", tool_call: call)).to eq("Hi Alice")
  end

  it "delegates native schema and approval metadata" do
    tool_class.requires_approval

    expect(wrapper.parameters_schema).to eq(tool.parameters_schema)
    expect(wrapper.requires_approval?).to be true
    expect(wrapper.provider_options).to eq(tool.provider_options)
  end

  it "lets RubyLLM handle tool failures" do
    allow(tool).to receive(:execute).and_raise("Unavailable")

    expect { described_class.new(tool, context).call(greeting: "Hi") }.to raise_error("Unavailable")
  end
end
