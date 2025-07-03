# frozen_string_literal: true

require "spec_helper"

RSpec.describe Agents::MCP::Manager do
  let(:manager) { described_class.new }

  describe "#initialize" do
    it "creates manager with default options" do
      expect(manager.options[:connection_retry_attempts]).to eq(2)
      expect(manager.options[:enable_fallback_mode]).to be true
      expect(manager.options[:handle_collisions]).to eq(:prefix)
    end

    it "accepts custom options" do
      custom_manager = described_class.new(
        connection_retry_attempts: 5,
        enable_fallback_mode: false,
        handle_collisions: :error
      )

      expect(custom_manager.options[:connection_retry_attempts]).to eq(5)
      expect(custom_manager.options[:enable_fallback_mode]).to be false
      expect(custom_manager.options[:handle_collisions]).to eq(:error)
    end

    it "initializes empty collections" do
      expect(manager.clients).to be_empty
    end
  end

  describe "#add_client" do
    it "adds a new MCP client" do
      client = manager.add_client(
        name: "test",
        command: "echo",
        args: ["hello"]
      )

      expect(client).to be_a(Agents::MCP::Client)
      expect(client.name).to eq("test")
      expect(manager.clients["test"]).to be(client)
    end

    it "raises error for duplicate client names" do
      manager.add_client(name: "test", command: "echo")

      expect do
        manager.add_client(name: "test", command: "echo")
      end.to raise_error(ArgumentError, /already exists/)
    end

    it "clears tools cache when adding clients" do
      # Add some cached data
      manager.instance_variable_set(:@tools_cache, { "old" => ["tool"] })

      manager.add_client(name: "test", command: "echo")

      expect(manager.instance_variable_get(:@tools_cache)).to be_empty
    end

    it "initializes client health tracking" do
      manager.add_client(name: "test", command: "echo")

      health = manager.instance_variable_get(:@client_health)
      expect(health["test"]).to include(
        healthy: false,
        last_check: nil,
        error: nil
      )
    end
  end

  describe "#remove_client" do
    it "removes an existing client" do
      client = manager.add_client(name: "test", command: "echo")
      expect(client).to receive(:disconnect)

      manager.remove_client("test")

      expect(manager.clients["test"]).to be_nil
    end

    it "handles disconnection errors gracefully" do
      client = manager.add_client(name: "test", command: "echo")
      expect(client).to receive(:disconnect).and_raise(StandardError, "Disconnect failed")

      expect { manager.remove_client("test") }.not_to raise_error
      expect(manager.clients["test"]).to be_nil
    end

    it "clears tools cache when removing clients" do
      manager.add_client(name: "test", command: "echo")
      manager.instance_variable_set(:@tools_cache, { "test" => ["tool"] })

      manager.remove_client("test")

      expect(manager.instance_variable_get(:@tools_cache)).to be_empty
    end
  end

  describe "#get_agent_tools" do
    let(:mock_client) { instance_double(Agents::MCP::Client, name: "test") }
    let(:mock_tool) { instance_double(Agents::MCP::Tool) }

    before do
      allow(mock_tool).to receive_message_chain(:class, :name).and_return("test_tool")
      manager.instance_variable_set(:@clients, { "test" => mock_client })
    end

    context "with healthy clients" do
      before do
        allow(manager).to receive(:client_healthy?).with("test").and_return(true)
      end

      it "returns tools from all healthy clients" do
        expect(mock_client).to receive(:list_tools).with(refresh: false).and_return([mock_tool])

        tools = manager.get_agent_tools

        expect(tools).to eq([mock_tool])
      end

      it "caches tools between calls" do
        expect(mock_client).to receive(:list_tools).once.and_return([mock_tool])

        # Call twice, should only hit client once
        manager.get_agent_tools
        tools = manager.get_agent_tools

        expect(tools).to eq([mock_tool])
      end

      it "refreshes tools when requested" do
        expect(mock_client).to receive(:list_tools).twice.and_return([mock_tool])

        manager.get_agent_tools
        manager.get_agent_tools(refresh: true)
      end
    end

    context "with unhealthy clients" do
      before do
        allow(manager).to receive(:client_healthy?).with("test").and_return(false)
      end

      it "skips unhealthy clients in fallback mode" do
        expect(mock_client).not_to receive(:list_tools)

        tools = manager.get_agent_tools

        expect(tools).to be_empty
      end

      it "raises error when fallback mode disabled" do
        manager = described_class.new(enable_fallback_mode: false)
        manager.instance_variable_set(:@clients, { "test" => mock_client })
        allow(manager).to receive(:client_healthy?).with("test").and_return(false)

        expect do
          manager.get_agent_tools
        end.to raise_error(Agents::MCP::ConnectionError, /unhealthy/)
      end
    end

    context "with tool name collisions" do
      let(:mock_client2) { instance_double(Agents::MCP::Client, name: "test2") }
      let(:mock_tool2) { instance_double(Agents::MCP::Tool) }

      before do
        allow(mock_tool2).to receive_message_chain(:class, :name).and_return("test_tool") # Same name
        manager.instance_variable_set(:@clients, {
                                        "test" => mock_client,
                                        "test2" => mock_client2
                                      })
        allow(manager).to receive(:client_healthy?).and_return(true)
      end

      it "prefixes colliding tool names by default" do
        allow(mock_client).to receive(:list_tools).and_return([mock_tool])
        allow(mock_client2).to receive(:list_tools).and_return([mock_tool2])

        # Mock tool creation for collision resolution
        prefixed_tool = instance_double(Agents::Tool)
        allow(prefixed_tool).to receive_message_chain(:class, :name).and_return("test2__test_tool")

        expect(manager).to receive(:create_prefixed_tool)
          .with(mock_tool2, "test2__test_tool", "test2")
          .and_return(prefixed_tool)

        tools = manager.get_agent_tools

        expect(tools).to include(mock_tool, prefixed_tool)
      end

      it "raises error when collision handling is set to error" do
        manager = described_class.new(handle_collisions: :error, enable_fallback_mode: false)
        manager.instance_variable_set(:@clients, {
                                        "test" => mock_client,
                                        "test2" => mock_client2
                                      })
        allow(manager).to receive(:client_healthy?).and_return(true)
        allow(mock_client).to receive(:list_tools).and_return([mock_tool])
        allow(mock_client2).to receive(:list_tools).and_return([mock_tool2])

        expect do
          manager.get_agent_tools
        end.to raise_error(Agents::MCP::ProtocolError, /collision/)
      end
    end

    context "with client errors" do
      before do
        allow(manager).to receive(:client_healthy?).with("test").and_return(true)
      end

      it "handles client errors in fallback mode" do
        expect(mock_client).to receive(:list_tools).and_raise(StandardError, "Client error")
        expect(manager).to receive(:handle_client_error).with("test", instance_of(StandardError))

        tools = manager.get_agent_tools

        expect(tools).to be_empty
      end

      it "raises error when fallback mode disabled" do
        manager = described_class.new(enable_fallback_mode: false)
        manager.instance_variable_set(:@clients, { "test" => mock_client })
        allow(manager).to receive(:client_healthy?).with("test").and_return(true)

        expect(mock_client).to receive(:list_tools).and_raise(StandardError, "Client error")

        expect do
          manager.get_agent_tools
        end.to raise_error(StandardError, "Client error")
      end
    end
  end

  describe "#execute_tool" do
    let(:mock_client) { instance_double(Agents::MCP::Client, name: "test") }
    let(:mock_tool_result) { instance_double(Agents::MCP::ToolResult, to_s: "tool result") }

    before do
      # Add missing mock methods for client health checks
      allow(mock_client).to receive(:connect)
      allow(mock_client).to receive(:connected?).and_return(true)

      manager.instance_variable_set(:@clients, { "test" => mock_client })
      manager.instance_variable_set(:@tools_cache, {
                                      "test" => [
                                        instance_double(Agents::Tool, class: double(name: "test_tool"))
                                      ]
                                    })
    end

    it "executes tool successfully" do
      expect(mock_client).to receive(:call_tool)
        .with("test_tool", { arg: "value" })
        .and_return(mock_tool_result)

      result = manager.execute_tool("test_tool", { arg: "value" })

      expect(result).to be_a(described_class::ToolExecutionResult)
      expect(result.success?).to be true
      expect(result.result).to be(mock_tool_result)
      expect(result.client_name).to eq("test")
    end

    it "handles tool execution errors" do
      expect(mock_client).to receive(:call_tool).and_raise(StandardError, "Execution failed")
      expect(manager).to receive(:handle_client_error).with("test", instance_of(StandardError))

      result = manager.execute_tool("test_tool", {})

      expect(result.success?).to be false
      expect(result.error).to eq("Execution failed")
    end

    it "returns error for unknown tools" do
      result = manager.execute_tool("unknown_tool", {})

      expect(result.success?).to be false
      expect(result.error).to eq("Tool 'unknown_tool' not found")
    end

    it "handles collision-prefixed tool names" do
      # Tool with collision prefix
      manager.instance_variable_set(:@tools_cache, {
                                      "test" => [
                                        instance_double(Agents::Tool, class: double(name: "test__original_tool"))
                                      ]
                                    })

      expect(mock_client).to receive(:call_tool)
        .with("original_tool", {}) # Original name extracted
        .and_return(mock_tool_result)

      result = manager.execute_tool("test__original_tool", {})

      expect(result.success?).to be true
    end
  end

  describe "#client_healthy?" do
    let(:mock_client) { instance_double(Agents::MCP::Client, name: "test") }

    before do
      manager.instance_variable_set(:@clients, { "test" => mock_client })
    end

    it "returns true for healthy clients" do
      # Client starts disconnected, then connects successfully
      expect(mock_client).to receive(:connected?).and_return(false).ordered
      expect(mock_client).to receive(:connect).ordered
      expect(mock_client).to receive(:connected?).and_return(true).ordered

      result = manager.client_healthy?("test")

      expect(result).to be true
    end

    it "returns false for unhealthy clients" do
      expect(mock_client).to receive(:connect).and_raise(StandardError, "Connection failed")
      expect(mock_client).to receive(:connected?).and_return(false)

      result = manager.client_healthy?("test")

      expect(result).to be false
    end

    it "caches health check results" do
      expect(mock_client).to receive(:connected?).and_return(false, true).at_least(:once)
      expect(mock_client).to receive(:connect).once

      # Call twice within cache window
      manager.client_healthy?("test")
      result = manager.client_healthy?("test")

      expect(result).to be true
    end

    it "returns false for non-existent clients" do
      result = manager.client_healthy?("nonexistent")
      expect(result).to be false
    end
  end

  describe "#client_health_status" do
    it "returns health status for all clients" do
      manager.add_client(name: "test1", command: "echo")
      manager.add_client(name: "test2", command: "echo")

      # Set some health data
      manager.instance_variable_set(:@client_health, {
                                      "test1" => { healthy: true, last_check: Time.now, error: nil },
                                      "test2" => { healthy: false, last_check: Time.now, error: "Connection failed" }
                                    })

      status = manager.client_health_status

      expect(status["test1"]).to include(healthy: true, status: "connected")
      expect(status["test2"]).to include(healthy: false, status: "disconnected")
    end
  end

  describe "#refresh_all_clients" do
    let(:mock_client1) { instance_double(Agents::MCP::Client, name: "test1") }
    let(:mock_client2) { instance_double(Agents::MCP::Client, name: "test2") }

    before do
      manager.instance_variable_set(:@clients, {
                                      "test1" => mock_client1,
                                      "test2" => mock_client2
                                    })
    end

    it "refreshes all clients successfully" do
      expect(mock_client1).to receive(:connected?).and_return(true)
      expect(mock_client1).to receive(:disconnect)
      expect(mock_client1).to receive(:connect)
      expect(mock_client1).to receive(:invalidate_tools_cache)

      expect(mock_client2).to receive(:connected?).and_return(false)
      expect(mock_client2).to receive(:connect)
      expect(mock_client2).to receive(:invalidate_tools_cache)

      results = manager.refresh_all_clients

      expect(results["test1"]).to eq({ success: true, error: nil })
      expect(results["test2"]).to eq({ success: true, error: nil })
    end

    it "handles client refresh errors" do
      expect(mock_client1).to receive(:connected?).and_return(false)
      expect(mock_client1).to receive(:connect).and_raise(StandardError, "Refresh failed")
      expect(manager).to receive(:handle_client_error).with("test1", instance_of(StandardError))

      # Mock the other client to succeed
      expect(mock_client2).to receive(:connected?).and_return(false)
      expect(mock_client2).to receive(:connect)
      expect(mock_client2).to receive(:invalidate_tools_cache)

      results = manager.refresh_all_clients

      expect(results["test1"]).to eq({ success: false, error: "Refresh failed" })
      expect(results["test2"]).to eq({ success: true, error: nil })
    end

    it "clears manager cache" do
      manager.instance_variable_set(:@tools_cache, { "test" => ["tool"] })

      allow(mock_client1).to receive(:connected?).and_return(false)
      allow(mock_client1).to receive(:connect)
      allow(mock_client1).to receive(:invalidate_tools_cache)
      allow(mock_client2).to receive(:connected?).and_return(false)
      allow(mock_client2).to receive(:connect)
      allow(mock_client2).to receive(:invalidate_tools_cache)

      manager.refresh_all_clients

      expect(manager.instance_variable_get(:@tools_cache)).to be_empty
    end
  end

  describe "#shutdown" do
    let(:mock_client1) { instance_double(Agents::MCP::Client, name: "test1") }
    let(:mock_client2) { instance_double(Agents::MCP::Client, name: "test2") }

    before do
      manager.instance_variable_set(:@clients, {
                                      "test1" => mock_client1,
                                      "test2" => mock_client2
                                    })
    end

    it "disconnects all clients" do
      expect(mock_client1).to receive(:disconnect)
      expect(mock_client2).to receive(:disconnect)

      manager.shutdown

      expect(manager.clients).to be_empty
    end

    it "handles disconnection errors gracefully" do
      expect(mock_client1).to receive(:disconnect).and_raise(StandardError, "Disconnect failed")
      expect(mock_client2).to receive(:disconnect)

      expect { manager.shutdown }.not_to raise_error
      expect(manager.clients).to be_empty
    end

    it "clears all internal state" do
      manager.instance_variable_set(:@tools_cache, { "test" => ["tool"] })
      manager.instance_variable_set(:@client_health, { "test" => {} })

      allow(mock_client1).to receive(:disconnect)
      allow(mock_client2).to receive(:disconnect)

      manager.shutdown

      expect(manager.instance_variable_get(:@tools_cache)).to be_empty
      expect(manager.instance_variable_get(:@client_health)).to be_empty
    end
  end

  describe "ToolExecutionResult" do
    let(:result_success) do
      described_class::ToolExecutionResult.new(
        success: true,
        result: "success result",
        client_name: "test",
        tool_name: "test_tool"
      )
    end

    let(:result_failure) do
      described_class::ToolExecutionResult.new(
        success: false,
        error: "execution failed",
        client_name: "test",
        tool_name: "test_tool"
      )
    end

    describe "#success?" do
      it "returns true for successful results" do
        expect(result_success.success?).to be true
      end

      it "returns false for failed results" do
        expect(result_failure.success?).to be false
      end
    end

    describe "#failure?" do
      it "returns false for successful results" do
        expect(result_success.failure?).to be false
      end

      it "returns true for failed results" do
        expect(result_failure.failure?).to be true
      end
    end

    describe "#to_s" do
      it "returns result for successful executions" do
        expect(result_success.to_s).to eq("success result")
      end

      it "returns error message for failed executions" do
        expect(result_failure.to_s).to eq("Error: execution failed")
      end

      it "handles complex result objects" do
        complex_result = described_class::ToolExecutionResult.new(
          success: true,
          result: { "data" => "value", "status" => "ok" }
        )

        expect(complex_result.to_s).to eq('{"data" => "value", "status" => "ok"}')
      end
    end
  end

  describe "thread safety" do
    it "handles concurrent client additions safely" do
      threads = []
      results = []
      mutex = Mutex.new

      10.times do |i|
        threads << Thread.new do
          client = manager.add_client(name: "test#{i}", command: "echo")
          mutex.synchronize { results << client.name }
        end
      end

      threads.each(&:join)

      expect(results).to have_attributes(size: 10)
      expect(results.uniq).to eq(results) # All unique
      expect(manager.clients.keys.size).to eq(10)
    end

    it "handles concurrent tool requests safely" do
      # Setup a mock client with tools
      mock_client = instance_double(Agents::MCP::Client, name: "test")
      mock_tool_result = instance_double(Agents::MCP::ToolResult, to_s: "result")

      manager.instance_variable_set(:@clients, { "test" => mock_client })
      manager.instance_variable_set(:@tools_cache, {
                                      "test" => [instance_double(Agents::Tool, class: double(name: "test_tool"))]
                                    })

      allow(mock_client).to receive(:call_tool).and_return(mock_tool_result)
      allow(mock_client).to receive(:connect)
      allow(mock_client).to receive(:connected?).and_return(true)

      threads = []
      results = []
      mutex = Mutex.new

      5.times do |i|
        threads << Thread.new do
          result = manager.execute_tool("test_tool", { index: i })
          mutex.synchronize { results << result }
        end
      end

      threads.each(&:join)

      expect(results).to have_attributes(size: 5)
      results.each { |result| expect(result.success?).to be true }
    end
  end
end
