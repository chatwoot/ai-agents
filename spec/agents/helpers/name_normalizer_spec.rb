# frozen_string_literal: true

require "spec_helper"

RSpec.describe Agents::Helpers::NameNormalizer do
  describe ".to_tool_name" do
    context "with uppercase characters" do
      it "converts to lowercase" do
        expect(described_class.to_tool_name("UPPERCASE")).to eq("uppercase")
      end
    end

    context "with spaces" do
      it "replaces spaces with underscores" do
        expect(described_class.to_tool_name("Agent With Spaces")).to eq("agent_with_spaces")
      end

      it "replaces multiple consecutive spaces with a single underscore" do
        expect(described_class.to_tool_name("Agent  With   Spaces")).to eq("agent_with_spaces")
      end
    end

    context "with special characters" do
      it "removes special characters" do
        expect(described_class.to_tool_name("Agent-Name!@#")).to eq("agentname")
      end

      it "removes hyphens" do
        expect(described_class.to_tool_name("billing-agent")).to eq("billingagent")
      end
    end

    context "with already valid names" do
      it "preserves valid characters" do
        expect(described_class.to_tool_name("agent_name_123")).to eq("agent_name_123")
      end
    end

    context "with mixed input" do
      it "handles spaces and special characters together" do
        expect(described_class.to_tool_name("Support Agent (v2)")).to eq("support_agent_v2")
      end
    end
  end
end
