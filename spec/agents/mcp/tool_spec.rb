# frozen_string_literal: true

require "spec_helper"

RSpec.describe Agents::MCP::Tool do
  let(:mock_client) { instance_double(Agents::MCP::Client, name: "test_client") }

  describe ".create_from_mcp_data" do
    context "with basic tool schema" do
      let(:basic_tool_schema) do
        {
          "name" => "read_file",
          "description" => "Read file contents",
          "inputSchema" => {
            "type" => "object",
            "properties" => {
              "path" => { "type" => "string", "description" => "File path" }
            },
            "required" => ["path"]
          }
        }
      end

      it "creates tool instance with correct attributes" do
        tool = described_class.create_from_mcp_data(basic_tool_schema, client: mock_client)

        expect(tool).to be_a(described_class)
        expect(tool.class.name).to eq("read_file")
        expect(tool.mcp_tool_name).to eq("read_file")
        expect(tool.mcp_client).to eq(mock_client)
      end

      it "creates tool with proper name method" do
        tool = described_class.create_from_mcp_data(basic_tool_schema, client: mock_client)

        expect(tool.class.name).to eq("read_file")
      end

      it "provides a debug-friendly inspect method" do
        tool = described_class.create_from_mcp_data(basic_tool_schema, client: mock_client)

        expect(tool.inspect).to match(/MCPTool\(read_file\)/)
      end
    end

    context "with tool execution" do
      let(:execution_tool_schema) do
        {
          "name" => "simple_tool",
          "description" => "A simple test tool",
          "inputSchema" => {
            "type" => "object",
            "properties" => {
              "input" => { "type" => "string", "description" => "Input parameter" }
            },
            "required" => ["input"]
          }
        }
      end

      it "can execute tool calls through MCP client" do
        tool = described_class.create_from_mcp_data(execution_tool_schema, client: mock_client)
        mock_result = instance_double(Agents::MCP::ToolResult)
        allow(mock_result).to receive(:to_s).and_return("Tool executed successfully")

        expect(mock_client).to receive(:call_tool)
          .with("simple_tool", { "input" => "test value" })
          .and_return(mock_result)

        # Mock a tool context
        tool_context = instance_double("ToolContext")

        result = tool.perform(tool_context, input: "test value")
        expect(result).to eq("Tool executed successfully")
      end

      it "handles execution errors gracefully" do
        tool = described_class.create_from_mcp_data(execution_tool_schema, client: mock_client)

        expect(mock_client).to receive(:call_tool)
          .with("simple_tool", { "input" => "test" })
          .and_raise(StandardError, "Connection failed")

        tool_context = instance_double("ToolContext")

        result = tool.perform(tool_context, input: "test")
        expect(result).to match(/Error calling MCP tool simple_tool.*Connection failed/)
      end
    end

    context "with missing or invalid schemas" do
      it "raises error for missing tool name" do
        invalid_schema = {
          "description" => "A tool without a name",
          "inputSchema" => { "type" => "object" }
        }

        expect do
          described_class.create_from_mcp_data(invalid_schema, client: mock_client)
        end.to raise_error(Agents::MCP::ProtocolError, "Tool missing name")
      end

      it "raises error for invalid input schema" do
        invalid_schema = {
          "name" => "test_tool",
          "description" => "Test tool",
          "inputSchema" => "not an object"
        }

        expect do
          described_class.create_from_mcp_data(invalid_schema, client: mock_client)
        end.to raise_error(Agents::MCP::ProtocolError, "Invalid input schema")
      end

      it "handles missing description gracefully" do
        schema_without_desc = {
          "name" => "no_desc_tool",
          "inputSchema" => { "type" => "object" }
        }

        tool = described_class.create_from_mcp_data(schema_without_desc, client: mock_client)

        expect(tool.class.name).to eq("no_desc_tool")
      end

      it "handles missing input schema gracefully" do
        schema_without_input = {
          "name" => "simple_tool",
          "description" => "Simple tool"
        }

        tool = described_class.create_from_mcp_data(schema_without_input, client: mock_client)

        expect(tool.class.name).to eq("simple_tool")
      end
    end
  end

  describe "#perform" do
    let(:tool_schema) do
      {
        "name" => "test_tool",
        "description" => "Test tool for perform method",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "input" => { "type" => "string", "description" => "Input value" }
          },
          "required" => ["input"]
        }
      }
    end

    let(:tool) { described_class.create_from_mcp_data(tool_schema, client: mock_client) }
    let(:tool_context) { instance_double("ToolContext") }

    it "calls MCP client with correct parameters" do
      args = { input: "test value" }
      expected_result = instance_double(Agents::MCP::ToolResult, to_s: "Tool result")

      expect(mock_client).to receive(:call_tool)
        .with("test_tool", { "input" => "test value" })
        .and_return(expected_result)

      result = tool.perform(tool_context, **args)

      expect(result).to eq("Tool result")
    end

    it "converts ToolResult to string for LLM" do
      args = { input: "test value" }
      tool_result = instance_double(Agents::MCP::ToolResult, to_s: "Formatted result")

      expect(mock_client).to receive(:call_tool)
        .with("test_tool", { "input" => "test value" })
        .and_return(tool_result)

      result = tool.perform(tool_context, **args)

      expect(result).to eq("Formatted result")
    end

    it "converts simple values to string" do
      args = { input: "test value" }

      expect(mock_client).to receive(:call_tool)
        .with("test_tool", { "input" => "test value" })
        .and_return({ status: "success", data: "result" })

      result = tool.perform(tool_context, **args)

      expect(result).to match(/status.*success.*data.*result/)
    end

    it "handles tool execution errors gracefully" do
      args = { input: "test value" }

      expect(mock_client).to receive(:call_tool)
        .with("test_tool", { "input" => "test value" })
        .and_raise(StandardError, "Connection failed")

      result = tool.perform(tool_context, **args)

      expect(result).to eq("Error calling MCP tool test_tool: Connection failed")
    end

    it "handles client errors gracefully" do
      args = { input: "test value" }

      expect(mock_client).to receive(:call_tool)
        .with("test_tool", { "input" => "test value" })
        .and_raise(Agents::MCP::ServerError, "Server unavailable")

      result = tool.perform(tool_context, **args)

      expect(result).to eq("Error calling MCP tool test_tool: Server unavailable")
    end
  end

  describe "#inspect" do
    let(:tool_schema) do
      {
        "name" => "inspect_test",
        "description" => "Test tool for inspect method"
      }
    end

    it "provides useful debug information" do
      tool = described_class.create_from_mcp_data(tool_schema, client: mock_client)

      inspect_result = tool.inspect

      expect(inspect_result).to match(/^#<MCPTool\(inspect_test\):\d+>$/)
    end
  end

  describe "tool name handling" do
    let(:tool_schema) do
      {
        "name" => "complex_tool_name",
        "description" => "Test tool name handling"
      }
    end

    it "provides the MCP tool name via singleton method" do
      tool = described_class.create_from_mcp_data(tool_schema, client: mock_client)

      expect(tool.class.name).to eq("complex_tool_name")
    end

    it "stores MCP tool name in instance" do
      tool = described_class.create_from_mcp_data(tool_schema, client: mock_client)

      expect(tool.mcp_tool_name).to eq("complex_tool_name")
    end

    it "stores MCP client reference" do
      tool = described_class.create_from_mcp_data(tool_schema, client: mock_client)

      expect(tool.mcp_client).to be(mock_client)
    end
  end

  describe "edge cases" do
    context "with empty properties" do
      let(:empty_schema) do
        {
          "name" => "empty_tool",
          "description" => "Tool with empty properties",
          "inputSchema" => {
            "type" => "object",
            "properties" => {}
          }
        }
      end

      it "creates tool successfully" do
        tool = described_class.create_from_mcp_data(empty_schema, client: mock_client)

        expect(tool.class.name).to eq("empty_tool")
        expect(tool).to be_a(described_class)
      end
    end

    context "with missing properties section" do
      let(:no_props_schema) do
        {
          "name" => "no_props_tool",
          "description" => "Tool without properties section",
          "inputSchema" => {
            "type" => "object"
          }
        }
      end

      it "creates tool successfully" do
        tool = described_class.create_from_mcp_data(no_props_schema, client: mock_client)

        expect(tool.class.name).to eq("no_props_tool")
        expect(tool).to be_a(described_class)
      end
    end

    context "with missing required section" do
      let(:no_required_schema) do
        {
          "name" => "no_required_tool",
          "description" => "Tool without required section",
          "inputSchema" => {
            "type" => "object",
            "properties" => {
              "optional_param" => { "type" => "string", "description" => "Optional parameter" }
            }
          }
        }
      end

      it "creates tool successfully" do
        tool = described_class.create_from_mcp_data(no_required_schema, client: mock_client)

        expect(tool.class.name).to eq("no_required_tool")
        expect(tool).to be_a(described_class)
      end
    end
  end
end
