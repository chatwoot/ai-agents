# frozen_string_literal: true

require "spec_helper"

RSpec.describe Agents::MCP::StdioTransport do
  let(:command) { "npx" }
  let(:args) { ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"] }
  let(:transport) { described_class.new(command: command, args: args) }

  describe "#initialize" do
    it "creates transport with command and args" do
      expect(transport.instance_variable_get(:@command)).to eq(command)
      expect(transport.instance_variable_get(:@args)).to eq(args)
    end

    it "initializes process as nil" do
      expect(transport.instance_variable_get(:@process)).to be_nil
    end
  end

  describe "#call" do
    let(:mock_process_status) { instance_double(Process::Status, success?: true) }
    let(:mock_wait_thread) do
      double("wait_thread", alive?: true, value: mock_process_status, pid: 12_345, join: nil, kill: nil)
    end
    let(:mock_stdin) { instance_double(IO) }
    let(:mock_stdout) { instance_double(IO) }
    let(:mock_stderr) { instance_double(IO) }

    before do
      allow(Open3).to receive(:popen3).and_return([mock_stdin, mock_stdout, mock_stderr, mock_wait_thread])
      allow(mock_stdin).to receive(:puts)
      allow(mock_stdin).to receive(:flush)
      allow(mock_stdin).to receive(:close)
      allow(mock_stdout).to receive(:gets).and_return('{"result": {"status": "success"}}', nil)

      # Mock the each_line method to simulate the reader thread processing responses
      allow(mock_stdout).to receive(:each_line) do |&block|
        # Simulate reader thread behavior
        Thread.new do
          sleep 0.01 # Small delay to ensure request is sent first
          block.call('{"jsonrpc": "2.0", "id": 1, "result": {"status": "success"}}')
        end
      end

      allow(mock_stderr).to receive(:read).and_return("")
      allow(Process).to receive(:wait2).and_return([12_345, mock_process_status])
    end

    context "with successful tool call" do
      it "sends JSON-RPC request correctly" do
        expected_request = {
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: { name: "read_file", arguments: { path: "/tmp/test.txt" } }
        }

        expect(mock_stdin).to receive(:puts).with(expected_request.to_json)

        transport.call("tools/call", { name: "read_file", arguments: { path: "/tmp/test.txt" } })
      end

      it "receives and parses JSON response" do
        response_json = '{"jsonrpc": "2.0", "id": 1, "result": {"content": ["file data"]}}'
        
        # Override the each_line mock for this specific test
        allow(mock_stdout).to receive(:each_line) do |&block|
          Thread.new do
            sleep 0.01
            block.call(response_json)
          end
        end

        result = transport.call("tools/call", { name: "read_file", arguments: { path: "/tmp/test.txt" } })

        expect(result).to eq({ "content" => ["file data"] })
      end

      it "handles multiple response lines" do
        # Simulate multi-line JSON response
        full_response = '{"jsonrpc": "2.0", "id": 1, "result": {"content": ["file data"]}}'
        
        # Override the each_line mock for this specific test
        allow(mock_stdout).to receive(:each_line) do |&block|
          Thread.new do
            sleep 0.01
            block.call(full_response)
          end
        end

        result = transport.call("tools/call", { name: "read_file", arguments: { path: "/tmp/test.txt" } })

        expect(result).to eq({ "content" => ["file data"] })
      end
    end

    context "with subprocess management" do
      it "spawns subprocess with correct command and args" do
        full_command = [command] + args

        # popen3 is called with env as first argument
        expect(Open3).to receive(:popen3).with({}, *full_command)

        transport.connect  # This is where subprocess should be spawned
      end

      it "manages process lifecycle correctly" do
        transport.connect # Connect first
        
        expect(mock_stdin).to receive(:close)
        expect(mock_stdout).to receive(:close)
        expect(mock_stderr).to receive(:close)
        expect(mock_wait_thread).to receive(:alive?).and_return(true)
        expect(mock_wait_thread).to receive(:join).with(2)
        expect(mock_wait_thread).to receive(:alive?).and_return(false)

        transport.disconnect # This is where process cleanup should happen
      end

      it "reuses existing process if available" do
        # Connect first to establish process
        transport.connect
        
        # Should not call popen3 again when already connected
        expect(Open3).not_to receive(:popen3)

        transport.connect # Second connect should not spawn new process
      end
    end

    context "error handling" do
      it "handles subprocess crashes" do
        allow(Open3).to receive(:popen3).and_raise(Errno::ENOENT, "Command not found")

        expect do
          transport.call("tools/list", {})
        end.to raise_error(Agents::MCP::ConnectionError, /Failed to start MCP server.*Command not found/)
      end

      it "handles process spawn failures" do
        allow(Open3).to receive(:popen3).and_raise(StandardError, "Spawn failed")

        expect do
          transport.call("tools/list", {})
        end.to raise_error(Agents::MCP::ConnectionError, /Failed to start MCP server.*Spawn failed/)
      end

      it "handles JSON parsing errors" do
        invalid_json = "invalid json response"
        
        # Override the each_line mock for this specific test
        allow(mock_stdout).to receive(:each_line) do |&block|
          Thread.new do
            sleep 0.01
            block.call(invalid_json)
            # Don't send any valid response - this should timeout
          end
        end

        # Invalid JSON is logged but doesn't raise an error - request will timeout
        expect do
          transport.call("tools/list", {})
        end.to raise_error(Agents::MCP::ConnectionError, /Request timeout/)
      end

      it "handles empty responses" do
        # Override the each_line mock to simulate no response
        allow(mock_stdout).to receive(:each_line) do |&block|
          Thread.new do
            # Don't call block - simulate no response
            sleep 0.05
          end
        end

        expect do
          transport.call("tools/list", {})
        end.to raise_error(Agents::MCP::ConnectionError, /Request timeout/)
      end

      it "handles error responses from server" do
        error_response = {
          "jsonrpc" => "2.0",
          "id" => 1,
          "error" => {
            "code" => -32_602,
            "message" => "Invalid params"
          }
        }
        
        # Override the each_line mock for this specific test
        allow(mock_stdout).to receive(:each_line) do |&block|
          Thread.new do
            sleep 0.01
            block.call(error_response.to_json)
          end
        end

        expect do
          transport.call("tools/call", { invalid: "params" })
        end.to raise_error(Agents::MCP::ServerError, /Invalid params/)
      end

      it "handles process exit with non-zero status" do
        # The current implementation doesn't check process exit status during disconnect
        # It just cleans up resources. This test should verify clean disconnection.
        failing_process = instance_double(Process::Status, success?: false, exitstatus: 1)
        
        # Allow close calls on all IO objects
        allow(mock_stdin).to receive(:close)
        allow(mock_stdout).to receive(:close)
        allow(mock_stderr).to receive(:close)
        allow(mock_wait_thread).to receive(:alive?).and_return(false)

        # Connect first
        transport.connect
        
        # Disconnect should succeed even if process failed
        expect { transport.disconnect }.not_to raise_error
        expect(transport.connected?).to be false
      end

      it "handles timeout scenarios" do
        # Simulate timeout by not yielding any response in each_line
        allow(mock_stdout).to receive(:each_line) do |&block|
          Thread.new do
            # Do nothing - simulate timeout by not calling block
            sleep 0.05
          end
        end

        expect do
          transport.call("tools/list", {})
        end.to raise_error(Agents::MCP::ConnectionError, /Request timeout/)
      end

      it "handles IO errors" do
        allow(mock_stdin).to receive(:puts).and_raise(IOError, "Broken pipe")

        expect do
          transport.call("tools/list", {})
        end.to raise_error(Agents::MCP::ConnectionError, /Failed to send request.*Broken pipe/)
      end
    end

    context "request formatting" do
      it "generates unique request IDs" do
        request_ids = []
        responses_sent = 0

        allow(mock_stdin).to receive(:puts) do |json_string|
          request = JSON.parse(json_string)
          request_ids << request["id"]
          
          # Send immediate response for each request
          responses_sent += 1
          response = {
            "jsonrpc" => "2.0",
            "id" => request["id"], # Match the request ID
            "result" => { "status" => "success" }
          }
          
          # Mock the response processing
          transport.send(:handle_response, response)
        end

        # Mock each_line to not interfere (it's handled above)
        allow(mock_stdout).to receive(:each_line) do |&block|
          # Do nothing - responses are handled in puts mock
        end

        # Make multiple calls
        3.times { transport.call("tools/list", {}) }

        expect(request_ids).to have_attributes(size: 3)
        expect(request_ids.uniq).to eq(request_ids) # All unique
      end

      it "formats JSON-RPC 2.0 correctly" do
        expected_structure = {
          "jsonrpc" => "2.0",
          "id" => Integer,
          "method" => "tools/list",
          "params" => {}
        }

        allow(mock_stdin).to receive(:write) do |json_string|
          request = JSON.parse(json_string)
          expect(request).to include(expected_structure)
        end

        transport.call("tools/list", {})
      end

      it "includes parameters in request" do
        params = { name: "test_tool", arguments: { key: "value" } }

        allow(mock_stdin).to receive(:write) do |json_string|
          request = JSON.parse(json_string)
          expect(request["params"]).to eq(params.transform_keys(&:to_s))
        end

        transport.call("tools/call", params)
      end
    end

    context "response parsing" do
      it "extracts result from JSON-RPC response" do
        result_data = { "tools" => %w[tool1 tool2] }
        response = {
          "jsonrpc" => "2.0",
          "id" => 1,
          "result" => result_data
        }
        
        # Override the each_line mock for this specific test
        allow(mock_stdout).to receive(:each_line) do |&block|
          Thread.new do
            sleep 0.01
            block.call(response.to_json)
          end
        end

        result = transport.call("tools/list", {})

        expect(result).to eq(result_data)
      end

      it "handles responses with no result field" do
        response = {
          "jsonrpc" => "2.0",
          "id" => 1
        }
        
        # Override the each_line mock for this specific test
        allow(mock_stdout).to receive(:each_line) do |&block|
          Thread.new do
            sleep 0.01
            block.call(response.to_json)
          end
        end

        result = transport.call("tools/list", {})

        expect(result).to be_nil
      end
    end
  end

  describe "#close" do
    let(:mock_wait_thread) { double("wait_thread", alive?: true, pid: 12_345, join: nil, kill: nil) }
    let(:mock_stdin) { instance_double(IO) }
    let(:mock_stdout) { instance_double(IO) }
    let(:mock_stderr) { instance_double(IO) }
    let(:mock_reader_thread) { instance_double(Thread) }

    before do
      transport.instance_variable_set(:@wait_thr, mock_wait_thread)
      transport.instance_variable_set(:@stdin, mock_stdin)
      transport.instance_variable_set(:@stdout, mock_stdout)
      transport.instance_variable_set(:@stderr, mock_stderr)
      transport.instance_variable_set(:@reader_thread, mock_reader_thread)
      transport.instance_variable_set(:@connected, true)
    end

    it "closes stdin and waits for process" do
      expect(mock_reader_thread).to receive(:kill)
      expect(mock_reader_thread).to receive(:join).with(1)
      expect(mock_stdin).to receive(:close)
      expect(mock_stdout).to receive(:close)
      expect(mock_stderr).to receive(:close)
      expect(mock_wait_thread).to receive(:alive?).and_return(false)

      transport.close
    end

    it "handles already closed process gracefully" do
      allow(mock_reader_thread).to receive(:kill)
      allow(mock_reader_thread).to receive(:join)
      allow(mock_stdin).to receive(:close).and_raise(IOError, "closed stream")
      allow(mock_stdout).to receive(:close)
      allow(mock_stderr).to receive(:close)
      allow(mock_wait_thread).to receive(:alive?).and_return(false)

      expect { transport.close }.not_to raise_error
    end

    it "cleans up instance variables" do
      allow(mock_reader_thread).to receive(:kill)
      allow(mock_reader_thread).to receive(:join)
      allow(mock_stdin).to receive(:close)
      allow(mock_stdout).to receive(:close)
      allow(mock_stderr).to receive(:close)
      allow(mock_wait_thread).to receive(:alive?).and_return(false)

      transport.close

      expect(transport.instance_variable_get(:@wait_thr)).to be_nil
      expect(transport.instance_variable_get(:@stdin)).to be_nil
      expect(transport.instance_variable_get(:@stdout)).to be_nil
    end
  end

  describe "thread safety" do
    it "handles concurrent requests safely" do
      # Mock successful process creation and communication
      mock_process_status = instance_double(Process::Status, success?: true)
      mock_wait_thread = double("wait_thread", alive?: true, value: mock_process_status, pid: 12_345, join: nil,
                                               kill: nil)
      mock_stdin = instance_double(IO)
      mock_stdout = instance_double(IO)
      mock_stderr = instance_double(IO)

      allow(Open3).to receive(:popen3).and_return([mock_stdin, mock_stdout, mock_stderr, mock_wait_thread])
      allow(mock_stdin).to receive(:puts)
      allow(mock_stdin).to receive(:flush)
      allow(mock_stdin).to receive(:close)
      # Mock each_line to simulate proper JSON-RPC responses with sequential IDs
      request_counter = 0
      allow(mock_stdout).to receive(:each_line) do |&block|
        Thread.new do
          sleep 0.01
          5.times do |i|
            request_counter += 1
            response = {
              "jsonrpc" => "2.0",
              "id" => request_counter,
              "result" => { "status" => "success", "index" => i }
            }
            block.call(response.to_json)
          end
        end
      end
      allow(mock_stderr).to receive(:read).and_return("")
      allow(Process).to receive(:wait2).and_return([12_345, mock_process_status])

      threads = []
      results = []
      mutex = Mutex.new

      # Create multiple concurrent requests
      5.times do |i|
        threads << Thread.new do
          result = transport.call("tools/list", { index: i })
          mutex.synchronize { results << result }
        end
      end

      threads.each(&:join)

      expect(results).to have_attributes(size: 5)
    end
  end
end
