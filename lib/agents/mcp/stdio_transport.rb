# frozen_string_literal: true

require "open3"
require "json"

module Agents
  module MCP
    # STDIO transport for communicating with MCP servers via subprocess.
    # This transport spawns a subprocess and communicates using JSON-RPC over stdin/stdout.
    # It handles concurrent requests using unique IDs and manages the subprocess lifecycle.
    #
    # @example Creating a STDIO transport
    #   transport = StdioTransport.new(
    #     command: "npx",
    #     args: ["-y", "@modelcontextprotocol/server-filesystem", "."],
    #     env: { "NODE_ENV" => "production" }
    #   )
    #   transport.connect
    class StdioTransport
      attr_reader :command, :args, :env

      # Initialize the STDIO transport
      #
      # @param command [String] The command to execute (e.g., "npx", "python")
      # @param args [Array<String>] Arguments for the command
      # @param env [Hash<String,String>] Environment variables for the subprocess
      def initialize(command:, args: [], env: {})
        @command = command
        @args = args
        @env = env
        @stdin = @stdout = @stderr = nil
        @wait_thr = nil
        @reader_thread = nil
        @request_id = 0
        @pending = {} # Map of request_id -> Queue for responses
        @connected = false
        @mutex = Mutex.new # Protect request_id and pending hash
      end

      # Connect to the MCP server by spawning the subprocess
      #
      # @raise [ConnectionError] If subprocess fails to start
      def connect
        return if @connected

        begin
          @stdin, @stdout, @stderr, @wait_thr = Open3.popen3(@env, @command, *@args)
          start_reader_thread
          @connected = true
        rescue StandardError => e
          raise ConnectionError, "Failed to start MCP server: #{e.message}"
        end
      end

      # Check if transport is connected
      #
      # @return [Boolean] True if connected to subprocess
      def connected?
        @connected && @wait_thr&.alive?
      end

      # Call an MCP method and return the result
      #
      # @param method [String] The MCP method name (e.g., "tools/list", "tools/call")
      # @param params [Hash] Parameters for the method call
      # @return [Hash] The result from the MCP server
      # @raise [ConnectionError] If not connected or communication fails
      # @raise [ProtocolError] If response parsing fails
      def call(method, params = {})
        # Auto-connect if not already connected
        connect unless connected?

        request = {
          "jsonrpc" => "2.0",
          "method" => method,
          "params" => params
        }

        response = send_request(request)

        # Handle nil response
        return nil if response.nil?

        if response.is_a?(Hash) && response["error"]
          error_msg = response["error"]["message"] || "Unknown server error"
          raise ServerError, "MCP server error: #{error_msg}"
        end

        response.is_a?(Hash) ? response["result"] : response
      end

      # Send a JSON-RPC request and wait for response
      #
      # @param request [Hash] The JSON-RPC request hash
      # @return [Hash] The parsed JSON response
      # @raise [ConnectionError] If not connected or communication fails
      # @raise [ProtocolError] If response parsing fails
      def send_request(request)
        raise ConnectionError, "Not connected" unless connected?

        request_id = nil
        response_queue = nil

        @mutex.synchronize do
          @request_id += 1
          request_id = @request_id
          response_queue = Queue.new
          @pending[request_id] = response_queue
        end

        # Add ID to request in proper order and send
        request_with_id = {
          "jsonrpc" => request["jsonrpc"],
          "id" => request_id,
          "method" => request["method"],
          "params" => request["params"]
        }

        begin
          @stdin.puts(request_with_id.to_json)
          @stdin.flush
        rescue StandardError => e
          @mutex.synchronize { @pending.delete(request_id) }
          raise ConnectionError, "Failed to send request: #{e.message}"
        end

        # Wait for response with timeout
        begin
          response = response_queue.pop(timeout: 30)

          raise response if response.is_a?(Exception)

          # Handle timeout case where response is nil
          if response.nil?
            raise ConnectionError, "Request timeout - no response received"
          end

          response
        rescue ThreadError => e
          @mutex.synchronize { @pending.delete(request_id) }
          raise ConnectionError, "Request timeout: #{e.message}"
        ensure
          @mutex.synchronize { @pending.delete(request_id) }
        end
      end

      # Disconnect from the MCP server
      def disconnect
        return unless @connected

        begin
          @reader_thread&.kill
          @reader_thread&.join(1)

          [@stdin, @stdout, @stderr].each do |io|
            io&.close
          rescue StandardError
            nil
          end

          if @wait_thr&.alive?
            begin
              Process.kill("TERM", @wait_thr.pid)
            rescue StandardError
              nil
            end
            @wait_thr.join(2)

            if @wait_thr.alive?
              begin
                Process.kill("KILL", @wait_thr.pid)
              rescue StandardError
                nil
              end
            end
          end
        rescue StandardError => e
          # Log error but don't raise - we're trying to clean up
          warn "Error during MCP transport disconnect: #{e.message}"
        ensure
          @connected = false
          @stdin = @stdout = @stderr = @wait_thr = @reader_thread = nil
          @pending.clear
        end
      end

      # Alias for disconnect to match test expectations
      alias close disconnect

      private

      # Start the background thread that reads responses from stdout
      def start_reader_thread
        @reader_thread = Thread.new do
          @stdout.each_line do |line|
            line = line.strip
            next if line.empty?

            begin
              response = JSON.parse(line)
              handle_response(response)
            rescue JSON::ParserError
              warn "Failed to parse MCP response: #{line}"
              # Continue reading other lines
            end
          end
        rescue StandardError => e
          # Notify all pending requests of the error
          @mutex.synchronize do
            @pending.each_value { |queue| queue.push(ConnectionError.new("Reader thread error: #{e.message}")) }
            @pending.clear
          end

          @connected = false
        end
      end

      # Handle a parsed JSON response
      #
      # @param response [Hash] The parsed JSON response
      def handle_response(response)
        response_id = response["id"]
        return unless response_id

        queue = nil
        @mutex.synchronize do
          queue = @pending[response_id]
        end

        return unless queue

        if response["error"]
          error_msg = response["error"]["message"] || "Unknown server error"
          error = ServerError.new("MCP server error: #{error_msg}")
          queue.push(error)
        else
          queue.push(response)
        end
      end
    end
  end
end
