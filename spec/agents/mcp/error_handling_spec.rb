# frozen_string_literal: true

require "spec_helper"

RSpec.describe "MCP Error Handling" do
  describe "Connection Errors" do
    let(:client) do
      Agents::MCP::Client.new(
        name: "test_client",
        command: "nonexistent_command"
      )
    end

    it "handles MCP server startup failures" do
      mock_transport = instance_double(Agents::MCP::StdioTransport)
      allow(Agents::MCP::StdioTransport).to receive(:new).and_return(mock_transport)
      allow(mock_transport).to receive(:connect)
      allow(mock_transport).to receive(:call).and_raise(Agents::MCP::ConnectionError, "Command not found")

      # Should not raise error, but should warn and return empty tools
      expect { client.list_tools }.not_to raise_error

      tools = client.list_tools
      expect(tools).to be_empty
    end

    it "handles transport connection failures" do
      mock_transport = instance_double(Agents::MCP::StdioTransport)
      allow(Agents::MCP::StdioTransport).to receive(:new).and_return(mock_transport)
      allow(mock_transport).to receive(:connect)
      allow(mock_transport).to receive(:call).and_raise(Errno::ECONNREFUSED, "Connection refused")

      expect do
        client.call_tool("test_tool", {})
      end.to raise_error(Agents::MCP::ServerError, /Failed to call tool.*Connection refused/)
    end

    it "handles network timeouts gracefully" do
      mock_transport = instance_double(Agents::MCP::StdioTransport)
      allow(Agents::MCP::StdioTransport).to receive(:new).and_return(mock_transport)
      allow(mock_transport).to receive(:connect)
      allow(mock_transport).to receive(:call).and_raise(Timeout::Error)

      expect do
        client.call_tool("test_tool", {})
      end.to raise_error(Agents::MCP::ServerError, /Failed to call tool.*Timeout/)
    end
  end

  describe "Protocol Errors" do
    let(:mock_transport) { instance_double(Agents::MCP::StdioTransport) }
    let(:client) do
      Agents::MCP::Client.new(name: "test", command: "test").tap do |c|
        c.instance_variable_set(:@transport, mock_transport)
      end
    end

    before do
      allow(mock_transport).to receive(:connect)
    end

    it "handles malformed MCP responses" do
      allow(mock_transport).to receive(:call)
        .with("tools/list", {})
        .and_return("invalid response format")

      # Should handle gracefully
      expect do
        client.list_tools
      end.not_to raise_error
      tools = client.list_tools
      expect(tools).to be_empty
    end

    it "handles missing tool schema fields" do
      invalid_tools_response = {
        "tools" => [
          {
            # Missing "name" field
            "description" => "A tool without a name",
            "inputSchema" => { "type" => "object" }
          }
        ]
      }

      allow(mock_transport).to receive(:call)
        .with("tools/list", {})
        .and_return(invalid_tools_response)

      # Should handle the error gracefully
      tools = client.list_tools
      expect(tools).to be_empty
    end

    it "handles invalid input schemas" do
      invalid_schema_response = {
        "tools" => [
          {
            "name" => "test_tool",
            "description" => "Test tool",
            "inputSchema" => "not an object" # Invalid schema
          }
        ]
      }

      allow(mock_transport).to receive(:call)
        .with("tools/list", {})
        .and_return(invalid_schema_response)

      tools = client.list_tools
      expect(tools).to be_empty
    end

    it "handles server error responses" do
      error_response = {
        "jsonrpc" => "2.0",
        "id" => 1,
        "error" => {
          "code" => -32_602,
          "message" => "Invalid params",
          "data" => { "details" => "Parameter validation failed" }
        }
      }

      allow(mock_transport).to receive(:call)
        .with("tools/call", anything)
        .and_return(error_response)

      expect do
        client.call_tool("test_tool", { invalid: "params" })
      end.to raise_error(Agents::MCP::ServerError, /Invalid params/)
    end

    it "handles missing error messages in server responses" do
      error_response = {
        "jsonrpc" => "2.0",
        "id" => 1,
        "error" => {
          "code" => -32_603
          # Missing "message" field
        }
      }

      allow(mock_transport).to receive(:call)
        .with("tools/call", anything)
        .and_return(error_response)

      expect do
        client.call_tool("test_tool", {})
      end.to raise_error(Agents::MCP::ServerError, /Unknown error/)
    end
  end

  describe "Tool Execution Errors" do
    let(:mock_transport) { instance_double(Agents::MCP::StdioTransport) }
    let(:valid_tool_response) do
      {
        "tools" => [
          {
            "name" => "test_tool",
            "description" => "Test tool",
            "inputSchema" => {
              "type" => "object",
              "properties" => {
                "param" => { "type" => "string", "description" => "Test parameter" }
              },
              "required" => ["param"]
            }
          }
        ]
      }
    end
    let(:client) do
      Agents::MCP::Client.new(name: "test", command: "test").tap do |c|
        c.instance_variable_set(:@transport, mock_transport)
      end
    end

    before do
      allow(mock_transport).to receive(:connect)
      allow(mock_transport).to receive(:call)
        .with("tools/list", {})
        .and_return(valid_tool_response)
    end

    it "handles tool execution timeouts" do
      allow(mock_transport).to receive(:call)
        .with("tools/call", anything)
        .and_raise(Timeout::Error)

      expect do
        client.call_tool("test_tool", { param: "value" })
      end.to raise_error(Agents::MCP::ServerError, /Failed to call tool.*Timeout/)
    end

    it "handles tool not found errors" do
      error_response = {
        "jsonrpc" => "2.0",
        "id" => 1,
        "error" => {
          "code" => -32_601,
          "message" => "Method not found: unknown_tool"
        }
      }

      allow(mock_transport).to receive(:call)
        .with("tools/call", anything)
        .and_return(error_response)

      expect do
        client.call_tool("unknown_tool", {})
      end.to raise_error(Agents::MCP::ServerError, /Method not found/)
    end

    it "handles invalid tool parameters" do
      error_response = {
        "jsonrpc" => "2.0",
        "id" => 1,
        "error" => {
          "code" => -32_602,
          "message" => "Invalid params: missing required parameter 'param'"
        }
      }

      allow(mock_transport).to receive(:call)
        .with("tools/call", anything)
        .and_return(error_response)

      expect do
        client.call_tool("test_tool", {}) # Missing required param
      end.to raise_error(Agents::MCP::ServerError, /Invalid params/)
    end

    it "handles tool execution internal errors" do
      error_response = {
        "jsonrpc" => "2.0",
        "id" => 1,
        "error" => {
          "code" => -32_603,
          "message" => "Internal error: file not found"
        }
      }

      allow(mock_transport).to receive(:call)
        .with("tools/call", anything)
        .and_return(error_response)

      expect do
        client.call_tool("test_tool", { param: "nonexistent" })
      end.to raise_error(Agents::MCP::ServerError, /Internal error/)
    end
  end

  describe "Manager Error Handling" do
    let(:manager) { Agents::MCP::Manager.new }

    describe "client health monitoring" do
      it "marks clients as unhealthy after failures" do
        mock_client = instance_double(Agents::MCP::Client, name: "test")
        manager.instance_variable_set(:@clients, { "test" => mock_client })

        # Mock connection failure
        allow(mock_client).to receive(:connect).and_raise(Agents::MCP::ConnectionError, "Failed")
        allow(mock_client).to receive(:connected?).and_return(false)

        healthy = manager.client_healthy?("test")
        expect(healthy).to be false

        health_status = manager.client_health_status
        expect(health_status["test"]).to include(
          healthy: false,
          error: "Failed"
        )
      end

      it "continues with other clients when one fails" do
        mock_client1 = instance_double(Agents::MCP::Client, name: "client1")
        mock_client2 = instance_double(Agents::MCP::Client, name: "client2")

        manager.instance_variable_set(:@clients, {
                                        "client1" => mock_client1,
                                        "client2" => mock_client2
                                      })

        # Client1 fails, Client2 succeeds
        allow(manager).to receive(:client_healthy?)
          .with("client1").and_return(false)
        allow(manager).to receive(:client_healthy?)
          .with("client2").and_return(true)

        mock_tool = instance_double(Agents::MCP::Tool)
        allow(mock_tool).to receive_message_chain(:class, :name).and_return("test_tool")
        allow(mock_client2).to receive(:list_tools).and_return([mock_tool])

        tools = manager.get_agent_tools
        expect(tools).to eq([mock_tool])
      end

      it "handles client addition failures gracefully" do
        expect do
          manager.add_client(name: "invalid", command: "nonexistent")
        end.not_to raise_error

        # Client should be added but marked as unhealthy
        expect(manager.clients["invalid"]).to be_a(Agents::MCP::Client)
      end
    end

    describe "fallback mode" do
      it "raises errors when fallback mode is disabled" do
        manager = Agents::MCP::Manager.new(enable_fallback_mode: false)
        mock_client = instance_double(Agents::MCP::Client, name: "test")
        manager.instance_variable_set(:@clients, { "test" => mock_client })

        allow(manager).to receive(:client_healthy?).with("test").and_return(false)

        expect do
          manager.get_agent_tools
        end.to raise_error(Agents::MCP::ConnectionError, /unhealthy/)
      end

      it "continues gracefully when fallback mode is enabled" do
        manager = Agents::MCP::Manager.new(enable_fallback_mode: true)
        mock_client = instance_double(Agents::MCP::Client, name: "test")
        manager.instance_variable_set(:@clients, { "test" => mock_client })

        allow(manager).to receive(:client_healthy?).with("test").and_return(false)

        tools = manager.get_agent_tools
        expect(tools).to be_empty
      end
    end

    describe "tool name collision handling" do
      let(:mock_client1) { instance_double(Agents::MCP::Client, name: "client1") }
      let(:mock_client2) { instance_double(Agents::MCP::Client, name: "client2") }
      let(:mock_tool1) { instance_double(Agents::MCP::Tool) }
      let(:mock_tool2) { instance_double(Agents::MCP::Tool) }

      before do
        allow(mock_tool1).to receive_message_chain(:class, :name).and_return("shared_tool")
        allow(mock_tool2).to receive_message_chain(:class, :name).and_return("shared_tool")

        manager.instance_variable_set(:@clients, {
                                        "client1" => mock_client1,
                                        "client2" => mock_client2
                                      })

        allow(manager).to receive(:client_healthy?).and_return(true)
        allow(mock_client1).to receive(:list_tools).and_return([mock_tool1])
        allow(mock_client2).to receive(:list_tools).and_return([mock_tool2])
      end

      it "raises error when collision handling is set to error" do
        manager = Agents::MCP::Manager.new(handle_collisions: :error, enable_fallback_mode: false)
        manager.instance_variable_set(:@clients, {
                                        "client1" => mock_client1,
                                        "client2" => mock_client2
                                      })

        allow(manager).to receive(:client_healthy?).and_return(true)
        allow(mock_client1).to receive(:list_tools).and_return([mock_tool1])
        allow(mock_client2).to receive(:list_tools).and_return([mock_tool2])

        expect do
          manager.get_agent_tools
        end.to raise_error(Agents::MCP::ProtocolError, /collision/)
      end

      it "handles collisions with ignore mode" do
        manager = Agents::MCP::Manager.new(handle_collisions: :ignore)
        manager.instance_variable_set(:@clients, {
                                        "client1" => mock_client1,
                                        "client2" => mock_client2
                                      })

        allow(manager).to receive(:client_healthy?).and_return(true)
        allow(mock_client1).to receive(:list_tools).and_return([mock_tool1])
        allow(mock_client2).to receive(:list_tools).and_return([mock_tool2])

        tools = manager.get_agent_tools
        expect(tools).to have_attributes(size: 2) # Both tools included, last one wins
      end
    end
  end

  describe "Agent Error Integration" do
    let(:agent_with_failing_mcp) do
      Agents::Agent.new(
        name: "Test Agent",
        instructions: "Test agent with failing MCP",
        mcp_clients: [{
          name: "failing_client",
          command: "nonexistent_command"
        }]
      )
    end

    it "continues functioning when MCP initialization fails" do
      # Agent should be created successfully even if MCP fails
      expect(agent_with_failing_mcp).to be_a(Agents::Agent)
      expect(agent_with_failing_mcp.name).to eq("Test Agent")

      # MCP tools should be empty due to failure
      tools = agent_with_failing_mcp.all_tools
      mcp_tools = tools.select { |t| t.is_a?(Agents::MCP::Tool) }
      expect(mcp_tools).to be_empty
    end

    it "provides health status for failed clients" do
      health = agent_with_failing_mcp.mcp_client_health
      expect(health).to have_key("failing_client")
      expect(health["failing_client"]).to include(healthy: false)
    end

    it "allows refresh attempts after initial failure" do
      # Initial state should show failure
      expect(agent_with_failing_mcp.mcp_manager).not_to be_nil

      # Refresh should not crash
      expect do
        agent_with_failing_mcp.refresh_mcp_tools
      end.not_to raise_error
    end
  end

  describe "Transport-Specific Error Handling" do
    describe "STDIO Transport" do
      let(:transport) do
        Agents::MCP::StdioTransport.new(
          command: "nonexistent_command",
          args: []
        )
      end

      it "handles command not found errors" do
        expect do
          transport.call("tools/list", {})
        end.to raise_error(Agents::MCP::ConnectionError, /Failed to start MCP server/)
      end
    end

    describe "HTTP Transport" do
      let(:transport) do
        Agents::MCP::HttpTransport.new(
          url: "http://nonexistent.example.com"
        )
      end

      it "handles DNS resolution failures" do
        # Mock DNS failure
        allow(Net::HTTP).to receive(:new).and_raise(SocketError, "getaddrinfo: Name or service not known")

        expect do
          transport.call("tools/list", {})
        end.to raise_error(Agents::MCP::ConnectionError, /Failed to connect/)
      end

      it "handles connection refused errors" do
        mock_http = instance_double(Net::HTTP)
        allow(Net::HTTP).to receive(:new).and_return(mock_http)
        allow(mock_http).to receive(:use_ssl=)
        allow(mock_http).to receive(:read_timeout=)
        allow(mock_http).to receive(:open_timeout=)
        allow(mock_http).to receive(:request).and_raise(Errno::ECONNREFUSED)

        expect do
          transport.call("tools/list", {})
        end.to raise_error(Agents::MCP::ConnectionError, /Failed to connect/)
      end
    end
  end

  describe "Resource Cleanup on Errors" do
    let(:manager) { Agents::MCP::Manager.new }

    it "cleans up resources properly during shutdown with errors" do
      mock_client1 = instance_double(Agents::MCP::Client, name: "client1")
      mock_client2 = instance_double(Agents::MCP::Client, name: "client2")

      manager.instance_variable_set(:@clients, {
                                      "client1" => mock_client1,
                                      "client2" => mock_client2
                                    })

      # First client disconnects successfully, second fails
      expect(mock_client1).to receive(:disconnect)
      expect(mock_client2).to receive(:disconnect).and_raise(StandardError, "Disconnect failed")

      # Should not raise error
      expect { manager.shutdown }.not_to raise_error

      # Should still clean up internal state
      expect(manager.clients).to be_empty
    end

    it "handles partial client refresh failures" do
      mock_client1 = instance_double(Agents::MCP::Client, name: "client1")
      mock_client2 = instance_double(Agents::MCP::Client, name: "client2")

      manager.instance_variable_set(:@clients, {
                                      "client1" => mock_client1,
                                      "client2" => mock_client2
                                    })

      # First client refreshes successfully
      allow(mock_client1).to receive(:connected?).and_return(false)
      allow(mock_client1).to receive(:connect)
      allow(mock_client1).to receive(:invalidate_tools_cache)

      # Second client fails during refresh
      allow(mock_client2).to receive(:connected?).and_return(false)
      allow(mock_client2).to receive(:connect).and_raise(StandardError, "Refresh failed")

      results = manager.refresh_all_clients

      expect(results["client1"]).to include(success: true)
      expect(results["client2"]).to include(success: false, error: "Refresh failed")
    end
  end
end
