# frozen_string_literal: true

require "spec_helper"

RSpec.describe "MCP Integration" do
  let(:mock_transport) { instance_double(Agents::MCP::StdioTransport) }

  describe "Real-world Usage Patterns" do
    let(:collaborative_agents_config) do
      [
        {
          name: "filesystem",
          command: "npx",
          args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
          include_tools: %w[read_file write_file]
        },
        {
          name: "database",
          url: "http://localhost:8001",
          include_tools: %w[query_users update_user]
        }
      ]
    end

    let(:file_agent) do
      Agents::Agent.new(
        name: "File Processor",
        instructions: "Process files and update database",
        mcp_clients: collaborative_agents_config
      )
    end

    before do
      # Mock both transports
      allow(Agents::MCP::StdioTransport).to receive(:new).and_return(mock_transport)

      # Add missing lifecycle methods for mock_transport
      allow(mock_transport).to receive(:connect)
      allow(mock_transport).to receive(:connected?).and_return(true)
      allow(mock_transport).to receive(:close)
      allow(mock_transport).to receive(:disconnect)

      mock_http_transport = instance_double(Agents::MCP::HttpTransport)
      allow(Agents::MCP::HttpTransport).to receive(:new).and_return(mock_http_transport)

      # Add lifecycle methods for HTTP transport mock
      allow(mock_http_transport).to receive(:connect)
      allow(mock_http_transport).to receive(:connected?).and_return(true)
      allow(mock_http_transport).to receive(:close)
      allow(mock_http_transport).to receive(:disconnect)

      # Mock responses for filesystem
      allow(mock_transport).to receive(:call)
        .with("tools/list", {})
        .and_return({
                      "tools" => [
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
                        },
                        {
                          "name" => "write_file",
                          "description" => "Write file contents",
                          "inputSchema" => {
                            "type" => "object",
                            "properties" => {
                              "path" => { "type" => "string", "description" => "File path" },
                              "content" => { "type" => "string", "description" => "File content" }
                            },
                            "required" => %w[path content]
                          }
                        }
                      ]
                    })

      allow(mock_http_transport).to receive(:call)
        .with("tools/list", {})
        .and_return({
                      "tools" => [
                        {
                          "name" => "query_users",
                          "description" => "Query user database",
                          "inputSchema" => {
                            "type" => "object",
                            "properties" => {
                              "query" => { "type" => "string", "description" => "SQL query" }
                            },
                            "required" => ["query"]
                          }
                        }
                      ]
                    })

      allow(mock_transport).to receive(:close)
      allow(mock_http_transport).to receive(:close)
    end

    it "supports multi-client workflows" do
      tools = file_agent.all_tools
      tool_names = tools.map { |t| t.class.name }

      expect(tool_names).to include("read_file", "write_file", "query_users")
    end

    it "maintains tool execution context across clients" do
      mcp_manager = file_agent.mcp_manager

      # Mock file read
      file_result = Agents::MCP::ToolResult.new(
        [{ "type" => "text", "text" => "user1,john@example.com\nuser2,jane@example.com" }],
        is_error: false
      )

      allow(mock_transport).to receive(:call)
        .with("tools/call", {
                "name" => "read_file",
                "arguments" => { "path" => "/tmp/users.csv" }
              })
        .and_return(file_result)

      # Execute file read
      read_result = mcp_manager.execute_tool("read_file", { "path" => "/tmp/users.csv" })

      expect(read_result.success?).to be true
      expect(read_result.client_name).to eq("filesystem")
      expect(read_result.to_s).to include("user1,john@example.com")
    end
  end
end
