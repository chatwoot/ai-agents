# frozen_string_literal: true

require "open3"
require "json"
require "thread"

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
        rescue => e
          raise ConnectionError, "Failed to start MCP server: #{e.message}"
        end
      end

      # Check if transport is connected
      #
      # @return [Boolean] True if connected to subprocess
      def connected?
        @connected && @wait_thr&.alive?
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

        # Add ID to request and send
        request_with_id = request.merge("id" => request_id)
        
        begin
          @stdin.puts(request_with_id.to_json)
          @stdin.flush
        rescue => e
          @mutex.synchronize { @pending.delete(request_id) }
          raise ConnectionError, "Failed to send request: #{e.message}"
        end

        # Wait for response with timeout
        begin
          response = response_queue.pop(timeout: 30)
          
          if response.is_a?(Exception)
            raise response
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
            io&.close rescue nil
          end

          if @wait_thr&.alive?
            Process.kill('TERM', @wait_thr.pid) rescue nil
            @wait_thr.join(2)
            
            if @wait_thr.alive?
              Process.kill('KILL', @wait_thr.pid) rescue nil
            end
          end
        rescue => e
          # Log error but don't raise - we're trying to clean up
          warn "Error during MCP transport disconnect: #{e.message}"
        ensure
          @connected = false
          @stdin = @stdout = @stderr = @wait_thr = @reader_thread = nil
          @pending.clear
        end
      end

      private

      # Start the background thread that reads responses from stdout
      def start_reader_thread
        @reader_thread = Thread.new do
          begin
            @stdout.each_line do |line|
              line = line.strip
              next if line.empty?

              begin
                response = JSON.parse(line)
                handle_response(response)
              rescue JSON::ParserError => e
                warn "Failed to parse MCP response: #{line}"
                # Continue reading other lines
              end
            end
          rescue => e
            # Notify all pending requests of the error
            @mutex.synchronize do
              @pending.each_value { |queue| queue.push(ConnectionError.new("Reader thread error: #{e.message}")) }
              @pending.clear
            end
            
            @connected = false
          end
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