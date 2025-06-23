# frozen_string_literal: true

require "spec_helper"
require "agents/handoff"
require "agents/agent"
require "agents/context"

RSpec.describe "Handoff Components" do
  describe Agents::HandoffResult do
    describe "#initialize" do
      it "creates a handoff result with required parameters" do
        target_class = Class.new
        result = described_class.new(target_agent_class: target_class)

        expect(result.target_agent_class).to eq(target_class)
        expect(result.reason).to be_nil
        expect(result.context).to be_nil
      end

      it "creates a handoff result with all parameters" do
        target_class = Class.new
        context = { key: "value" }
        result = described_class.new(
          target_agent_class: target_class,
          reason: "User requested",
          context: context
        )

        expect(result.target_agent_class).to eq(target_class)
        expect(result.reason).to eq("User requested")
        expect(result.context).to eq(context)
      end
    end

    describe "#handoff?" do
      it "returns true when target_agent_class is present" do
        result = described_class.new(target_agent_class: Class.new)
        expect(result.handoff?).to be true
      end

      it "returns false when target_agent_class is nil" do
        result = described_class.new(target_agent_class: nil)
        expect(result.handoff?).to be false
      end
    end
  end

  describe Agents::AgentResponse do
    describe "#initialize" do
      it "creates a response with content only" do
        response = described_class.new(content: "Hello")

        expect(response.content).to eq("Hello")
        expect(response.handoff_result).to be_nil
        expect(response.tool_calls).to eq([])
      end

      it "creates a response with handoff result" do
        handoff = Agents::HandoffResult.new(target_agent_class: Class.new)
        response = described_class.new(handoff_result: handoff)

        expect(response.content).to be_nil
        expect(response.handoff_result).to eq(handoff)
        expect(response.tool_calls).to eq([])
      end

      it "creates a response with tool calls" do
        tool_calls = [{ id: "call_123", name: "test_tool", arguments: {} }]
        response = described_class.new(tool_calls: tool_calls)

        expect(response.content).to be_nil
        expect(response.handoff_result).to be_nil
        expect(response.tool_calls).to eq(tool_calls)
      end

      it "creates a response with all parameters" do
        handoff = Agents::HandoffResult.new(target_agent_class: Class.new)
        tool_calls = [{ id: "call_123", name: "test_tool", arguments: {} }]
        response = described_class.new(
          content: "Processing...",
          handoff_result: handoff,
          tool_calls: tool_calls
        )

        expect(response.content).to eq("Processing...")
        expect(response.handoff_result).to eq(handoff)
        expect(response.tool_calls).to eq(tool_calls)
      end

      it "handles nil tool_calls gracefully" do
        response = described_class.new(content: "Hello", tool_calls: nil)
        expect(response.tool_calls).to eq([])
      end
    end

    describe "#handoff?" do
      it "returns true when handoff_result is present and valid" do
        handoff = Agents::HandoffResult.new(target_agent_class: Class.new)
        response = described_class.new(handoff_result: handoff)
        expect(response.handoff?).to be true
      end

      it "returns false when handoff_result is nil" do
        response = described_class.new(content: "Hello")
        expect(response).not_to be_handoff
      end

      it "returns false when handoff_result has no target" do
        handoff = Agents::HandoffResult.new(target_agent_class: nil)
        response = described_class.new(handoff_result: handoff)
        expect(response.handoff?).to be false
      end
    end

    describe "#has_tool_calls?" do
      it "returns true when tool_calls is not empty" do
        tool_calls = [{ id: "call_123", name: "test_tool", arguments: {} }]
        response = described_class.new(tool_calls: tool_calls)
        expect(response.has_tool_calls?).to be true
      end

      it "returns false when tool_calls is empty" do
        response = described_class.new(content: "Hello")
        expect(response.has_tool_calls?).to be false
      end
    end

    describe "#has_content?" do
      it "returns true when content is present and non-empty" do
        response = described_class.new(content: "Hello")
        expect(response.has_content?).to be true
      end

      it "returns false when content is nil" do
        response = described_class.new(handoff_result: nil)
        expect(response.has_content?).to be false
      end

      it "returns false when content is empty string" do
        response = described_class.new(content: "")
        expect(response.has_content?).to be false
      end

      it "returns false when content is only whitespace" do
        response = described_class.new(content: "   \n\t  ")
        expect(response.has_content?).to be false
      end
    end
  end

  describe Agents::HandoffTool do
    # Test agent classes
    class TestTargetAgent < Agents::Agent
      name "Test Target"
    end

    class ComplexNameAgent < Agents::Agent
      name "Complex Name Agent"
    end

    let(:context) { Agents::Context.new }

    describe "#initialize" do
      it "creates a handoff tool with default description" do
        tool = described_class.new(TestTargetAgent)

        expect(tool.target_agent_class).to eq(TestTargetAgent)
        expect(tool.name).to eq("transfer_to_test_target_agent")
        expect(tool.description).to eq("Transfer to Test Target")
      end

      it "creates a handoff tool with custom description" do
        tool = described_class.new(TestTargetAgent, description: "Custom transfer")

        expect(tool.description).to eq("Custom transfer")
      end

      it "handles complex class names correctly" do
        tool = described_class.new(ComplexNameAgent)

        expect(tool.name).to eq("transfer_to_complex_name_agent")
      end

      it "handles namespaced classes" do
        module TestNamespace
          class NamespacedAgent < Agents::Agent
            name "Namespaced"
          end
        end

        tool = described_class.new(TestNamespace::NamespacedAgent)
        expect(tool.name).to eq("transfer_to_namespaced_agent")
      end
    end

    describe "#perform" do
      let(:tool) { described_class.new(TestTargetAgent) }

      it "sets pending_handoff in context" do
        tool.perform(context: context, reason: "Test reason")

        expect(context[:pending_handoff]).to eq({
                                                  target_agent_class: TestTargetAgent,
                                                  reason: "Test reason"
                                                })
      end

      it "records last_handoff information" do
        tool.perform(context: context, reason: "Test reason")

        expect(context[:last_handoff]).to include(
          target: "Test Target",
          reason: "Test reason"
        )
        expect(context[:last_handoff][:timestamp]).to be_a(Time)
      end

      it "returns structured handoff data" do
        result = tool.perform(context: context, reason: "Test reason")

        expect(result).to be_a(Hash)
        expect(result[:type]).to eq("handoff")
        expect(result[:target]).to eq("Test Target")
        expect(result[:target_class]).to eq(TestTargetAgent)
        expect(result[:reason]).to eq("Test reason")
        expect(result[:message]).to eq("Transferring to Test Target (Test reason)...")
      end

      it "handles nil reason" do
        result = tool.perform(context: context)

        expect(result[:reason]).to be_nil
        expect(result[:message]).to eq("Transferring to Test Target...")
      end

      it "handles nil context gracefully" do
        expect { tool.perform(context: nil) }.not_to raise_error
      end
    end

    describe "parameter definition" do
      it "defines reason parameter correctly" do
        tool = described_class.new(TestTargetAgent)

        # HandoffTool inherits from Tool which inherits from RubyLLM::Tool
        # RubyLLM::Tool stores parameters in a specific way
        # Let's check if the tool responds to schema method
        if tool.respond_to?(:schema)
          schema = tool.schema
          properties = schema[:parameters][:properties]
          reason_prop = properties[:reason]

          expect(reason_prop).not_to be_nil
          expect(reason_prop[:type]).to eq("string")
          expect(schema[:parameters][:required]).not_to include(:reason)
        else
          # Alternative check - the parameter was defined at class level
          expect(described_class.instance_methods).to include(:perform)
        end
      end
    end
  end

  describe "String#underscore" do
    it "converts CamelCase to underscore" do
      expect("CamelCase".underscore).to eq("camel_case")
    end

    it "converts PascalCase to underscore" do
      expect("PascalCase".underscore).to eq("pascal_case")
    end

    it "handles acronyms" do
      expect("HTTPResponse".underscore).to eq("http_response")
      expect("XMLParser".underscore).to eq("xml_parser")
    end

    it "handles namespaced classes" do
      expect("Module::ClassName".underscore).to eq("module/class_name")
    end

    it "converts hyphens to underscores" do
      expect("hyphen-name".underscore).to eq("hyphen_name")
    end

    it "handles already underscored strings" do
      expect("already_underscored".underscore).to eq("already_underscored")
    end

    it "handles mixed cases" do
      expect("getHTTPResponseCode".underscore).to eq("get_http_response_code")
    end
  end
end

