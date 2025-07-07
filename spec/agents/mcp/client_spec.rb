# frozen_string_literal: true

require "spec_helper"

RSpec.describe Agents::MCP::Client do
  describe "#initialize" do
    context "with command-based configuration" do
      it "creates STDIO transport for command-based clients" do
        client = described_class.new(
          name: "filesystem",
          command: "npx",
          args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
        )

        expect(client.name).to eq("filesystem")
        expect(client.instance_variable_get(:@transport)).to be_a(Agents::MCP::StdioTransport)
      end

      it "raises error for missing command" do
        expect do
          described_class.new(name: "test")
        end.to raise_error(ArgumentError, /Must provide either command or url/)
      end

      it "raises error for missing name" do
        expect do
          described_class.new(command: "test")
        end.to raise_error(ArgumentError, /name is required/)
      end
    end

    context "with URL-based configuration" do
      it "creates HTTP transport for URL-based clients" do
        client = described_class.new(
          name: "api_server",
          url: "http://localhost:8000"
        )

        expect(client.name).to eq("api_server")
        expect(client.instance_variable_get(:@transport)).to be_a(Agents::MCP::HttpTransport)
      end

      it "accepts headers for HTTP transport" do
        headers = { "Authorization" => "Bearer token" }
        client = described_class.new(
          name: "api_server",
          url: "http://localhost:8000",
          headers: headers
        )

        transport = client.instance_variable_get(:@transport)
        actual_headers = transport.instance_variable_get(:@headers)
        # Check that our custom headers are included along with defaults
        expect(actual_headers).to include("Authorization" => "Bearer token")
        expect(actual_headers).to include("Accept" => "application/json")
        expect(actual_headers).to have_key("User-Agent")
      end
    end

    context "with tool filtering" do
      it "accepts include_tools configuration" do
        client = described_class.new(
          name: "filesystem",
          command: "test",
          include_tools: %w[read_file write_file]
        )

        expect(client.instance_variable_get(:@include_tools)).to eq(%w[read_file write_file])
      end

      it "accepts exclude_tools configuration" do
        client = described_class.new(
          name: "filesystem",
          command: "test",
          exclude_tools: ["delete_file"]
        )

        expect(client.instance_variable_get(:@exclude_tools)).to eq(["delete_file"])
      end

      it "accepts regex patterns for filtering" do
        client = described_class.new(
          name: "filesystem",
          command: "test",
          include_tools: [/^read_/, "write_file"]
        )

        expect(client.instance_variable_get(:@include_tools)).to include(/^read_/, "write_file")
      end
    end
  end

  describe "#list_tools" do
    let(:mock_transport) { instance_double(Agents::MCP::StdioTransport) }
    let(:client) do
      described_class.new(name: "test", command: "test").tap do |c|
        c.instance_variable_set(:@transport, mock_transport)
        c.instance_variable_set(:@connected, true)
      end
    end

    let(:sample_tools_response) do
      {
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
          },
          {
            "name" => "delete_file",
            "description" => "Delete a file",
            "inputSchema" => {
              "type" => "object",
              "properties" => {
                "path" => { "type" => "string", "description" => "File path" }
              },
              "required" => ["path"]
            }
          }
        ]
      }
    end

    it "fetches tools from MCP server" do
      expect(mock_transport).to receive(:call)
        .with("tools/list", {})
        .and_return(sample_tools_response)

      tools = client.list_tools

      expect(tools).to have_attributes(size: 3)
      expect(tools.map(&:name)).to eq(%w[read_file write_file delete_file])
    end

    it "applies include filters correctly" do
      client.instance_variable_set(:@include_tools, %w[read_file write_file])

      expect(mock_transport).to receive(:call)
        .with("tools/list", {})
        .and_return(sample_tools_response)

      tools = client.list_tools

      expect(tools).to have_attributes(size: 2)
      expect(tools.map(&:name)).to eq(%w[read_file write_file])
    end

    it "applies exclude filters correctly" do
      client.instance_variable_set(:@exclude_tools, ["delete_file"])

      expect(mock_transport).to receive(:call)
        .with("tools/list", {})
        .and_return(sample_tools_response)

      tools = client.list_tools

      expect(tools).to have_attributes(size: 2)
      expect(tools.map(&:name)).to eq(%w[read_file write_file])
    end

    it "applies regex include filters" do
      client.instance_variable_set(:@include_tools, [/^read_/])

      expect(mock_transport).to receive(:call)
        .with("tools/list", {})
        .and_return(sample_tools_response)

      tools = client.list_tools

      expect(tools).to have_attributes(size: 1)
      expect(tools.first.name).to eq("read_file")
    end

    it "handles server errors gracefully" do
      expect(mock_transport).to receive(:call)
        .with("tools/list", {})
        .and_raise(Agents::MCP::ServerError, "Server unavailable")

      # Updated expectation - client catches errors and returns empty array with warning
      tools = client.list_tools

      expect(tools).to be_empty
    end

    it "caches tool discovery results" do
      expect(mock_transport).to receive(:call)
        .with("tools/list", {})
        .once
        .and_return(sample_tools_response)

      # Call twice, should only hit transport once due to caching
      client.list_tools
      tools = client.list_tools

      expect(tools).to have_attributes(size: 3)
    end

    it "handles empty tools response" do
      expect(mock_transport).to receive(:call)
        .with("tools/list", {})
        .and_return({ "tools" => [] })

      tools = client.list_tools

      expect(tools).to be_empty
    end
  end

  describe "#call_tool" do
    let(:mock_transport) { instance_double(Agents::MCP::StdioTransport) }
    let(:client) do
      described_class.new(name: "test", command: "test").tap do |c|
        c.instance_variable_set(:@transport, mock_transport)
        c.instance_variable_set(:@connected, true)
      end
    end

    it "executes tools via transport layer" do
      args = { path: "/tmp/test.txt" }
      expected_response = { "content" => [{ "type" => "text", "text" => "Hello World" }] }

      expect(mock_transport).to receive(:call)
        .with("tools/call", {
                "name" => "read_file",
                "arguments" => args
              })
        .and_return(expected_response)

      result = client.call_tool("read_file", args)

      expect(result).to be_a(Agents::MCP::ToolResult)
      expect(result.to_s).to eq("Hello World")
    end

    it "converts arguments properly" do
      args = { path: "/tmp/test.txt", mode: "binary" }

      expect(mock_transport).to receive(:call)
        .with("tools/call", {
                "name" => "read_file",
                "arguments" => args
              })
        .and_return({ "content" => [{ "type" => "text", "text" => "data" }] })

      result = client.call_tool("read_file", args)

      expect(result).to be_a(Agents::MCP::ToolResult)
      expect(result.to_s).to eq("data")
    end

    it "handles tool execution errors" do
      args = { path: "/nonexistent/file.txt" }

      expect(mock_transport).to receive(:call)
        .with("tools/call", {
                "name" => "read_file",
                "arguments" => args
              })
        .and_raise(StandardError, "File not found")

      expect do
        client.call_tool("read_file", args)
      end.to raise_error(Agents::MCP::ServerError, /Failed to call tool read_file.*File not found/)
    end

    it "returns properly formatted results" do
      args = { path: "/tmp/test.txt" }
      response = {
        "content" => [
          {
            "type" => "text",
            "text" => "File contents here"
          }
        ]
      }

      expect(mock_transport).to receive(:call)
        .with("tools/call", {
                "name" => "read_file",
                "arguments" => args
              })
        .and_return(response)

      result = client.call_tool("read_file", args)

      expect(result).to be_a(Agents::MCP::ToolResult)
      expect(result.to_s).to eq("File contents here")
    end
  end

  describe "tool creation from server data" do
    let(:mock_transport) { instance_double(Agents::MCP::StdioTransport) }
    let(:client) do
      described_class.new(name: "test", command: "test").tap do |c|
        c.instance_variable_set(:@transport, mock_transport)
        c.instance_variable_set(:@connected, true)
      end
    end

    let(:sample_tool_data) do
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

    it "creates MCP tool instances from server data" do
      allow(mock_transport).to receive(:call)
        .with("tools/list", {})
        .and_return({ "tools" => [sample_tool_data] })

      tools = client.list_tools

      expect(tools).to have_attributes(size: 1)
      expect(tools.first).to be_a(Agents::MCP::Tool)
      expect(tools.first.name).to eq("read_file")
    end

    it "handles tool name collisions gracefully" do
      allow(mock_transport).to receive(:call)
        .with("tools/list", {})
        .and_return({ "tools" => [sample_tool_data, sample_tool_data] })

      # Should not raise error, should handle gracefully
      tools = client.list_tools

      expect(tools).to have_attributes(size: 1) # Duplicate should be filtered
    end

    it "handles invalid tool schemas" do
      invalid_tool = sample_tool_data.dup
      invalid_tool.delete("name")

      allow(mock_transport).to receive(:call)
        .with("tools/list", {})
        .and_return({ "tools" => [invalid_tool] })

      # Client should handle errors gracefully and return empty array
      tools = client.list_tools

      expect(tools).to be_empty
    end
  end

  describe "thread safety" do
    let(:client) do
      described_class.new(
        name: "filesystem",
        command: "test"
      )
    end

    it "handles concurrent tool calls safely" do
      mock_transport = instance_double(Agents::MCP::StdioTransport)
      client.instance_variable_set(:@transport, mock_transport)
      client.instance_variable_set(:@connected, true)

      # Simulate concurrent calls
      expect(mock_transport).to receive(:call).twice.and_return({ "content" => [{ "type" => "text",
                                                                                  "text" => "result" }] })

      threads = []
      results = []
      mutex = Mutex.new

      2.times do |i|
        threads << Thread.new do
          result = client.call_tool("test_tool", { arg: i })
          mutex.synchronize { results << result }
        end
      end

      threads.each(&:join)

      expect(results).to have_attributes(size: 2)
      results.each { |result| expect(result).to be_a(Agents::MCP::ToolResult) }
    end

    it "maintains separate transport connections" do
      # This test ensures that each client maintains its own transport
      client1 = described_class.new(name: "test1", command: "test1")
      client2 = described_class.new(name: "test2", command: "test2")

      transport1 = client1.instance_variable_get(:@transport)
      transport2 = client2.instance_variable_get(:@transport)

      expect(transport1).not_to be(transport2)
      expect(transport1.instance_variable_get(:@command)).to eq("test1")
      expect(transport2.instance_variable_get(:@command)).to eq("test2")
    end
  end

  describe "cache management" do
    let(:mock_transport) { instance_double(Agents::MCP::StdioTransport) }
    let(:client) do
      described_class.new(name: "test", command: "test").tap do |c|
        c.instance_variable_set(:@transport, mock_transport)
        c.instance_variable_set(:@connected, true)
      end
    end

    it "refreshes tools when refresh flag is set" do
      initial_response = { "tools" => [{ "name" => "tool1", "description" => "Tool 1", "inputSchema" => {} }] }
      updated_response = { "tools" => [{ "name" => "tool2", "description" => "Tool 2", "inputSchema" => {} }] }

      expect(mock_transport).to receive(:call)
        .with("tools/list", {})
        .and_return(initial_response)

      # Initial discovery
      tools = client.list_tools
      expect(tools.map(&:name)).to eq(["tool1"])

      expect(mock_transport).to receive(:call)
        .with("tools/list", {})
        .and_return(updated_response)

      # Refresh should clear cache and re-discover
      refreshed_tools = client.list_tools(refresh: true)
      expect(refreshed_tools.map(&:name)).to eq(["tool2"])
    end

    it "invalidates cache when requested" do
      response = { "tools" => [{ "name" => "tool1", "description" => "Tool 1", "inputSchema" => {} }] }

      expect(mock_transport).to receive(:call)
        .with("tools/list", {})
        .twice
        .and_return(response)

      # Load tools first time
      client.list_tools

      # Invalidate cache
      client.invalidate_tools_cache

      # Next call should hit transport again
      tools = client.list_tools
      expect(tools.map(&:name)).to eq(["tool1"])
    end
  end
end
