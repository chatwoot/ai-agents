# frozen_string_literal: true

module Agents
  module MCP
    # Stdio transport for local MCP servers running as subprocesses
    class StdioTransport
      attr_reader :command, :args, :env

      def initialize(options)
        @command = options[:command] || raise(ArgumentError, "command is required for stdio transport")
        @args = options[:args] || []
        @env = options[:env] || {}
        @timeout = options[:timeout] || 30
        @stdin = nil
        @stdout = nil
        @stderr = nil
        @wait_thread = nil
        @reader_thread = nil
        @response_queue = Queue.new
        @pending_requests = {}
        @mutex = Mutex.new
      end

      def connect
        # Spawn the MCP server process
        @stdin, @stdout, @stderr, @wait_thread = Open3.popen3(@env, @command, *@args)

        # Start background thread to read responses
        start_reader_thread

        # Perform MCP initialization handshake if needed
        initialize_session
      end

      def disconnect
        # Stop reader thread
        @reader_thread&.kill
        @reader_thread = nil

        # Close IO streams
        @stdin&.close
        @stdout&.close
        @stderr&.close

        # Terminate process if still running
        if @wait_thread&.alive?
          begin
            Process.kill("TERM", @wait_thread.pid)
          rescue StandardError
            nil
          end
          sleep(1)
          if @wait_thread.alive?
            begin
              Process.kill("KILL", @wait_thread.pid)
            rescue StandardError
              nil
            end
          end
        end

        @wait_thread = nil
        @stdin = @stdout = @stderr = nil
      end

      def send_request(request)
        request_id = request[:id]

        @mutex.synchronize do
          @pending_requests[request_id] = true
        end

        # Send request as JSON line
        json_request = JSON.generate(request)
        @stdin.puts(json_request)
        @stdin.flush

        # Wait for response
        response = wait_for_response(request_id)

        @mutex.synchronize do
          @pending_requests.delete(request_id)
        end

        response
      end

      private

      def start_reader_thread
        @reader_thread = Thread.new do
          while (line = @stdout.gets)
            line = line.strip
            next if line.empty?

            begin
              response = JSON.parse(line)
              @response_queue.push(response)
            rescue JSON::ParserError => e
              warn "Failed to parse MCP response: #{e.message}"
              warn "Raw line: #{line}"
            end
          end
        rescue IOError
          # Process terminated or IO closed
        end
      end

      def wait_for_response(request_id)
        start_time = Time.now

        loop do
          # Check for timeout
          raise ConnectionError, "Request timeout after #{@timeout} seconds" if Time.now - start_time > @timeout

          # Try to get response from queue (non-blocking)
          begin
            response = @response_queue.pop(true)
            return response if response["id"] == request_id

            # Not our response, put it back
            @response_queue.push(response)
            sleep(0.01)
          rescue ThreadError
            # Queue is empty, sleep and retry
            sleep(0.01)
          end
        end
      end

      def initialize_session
        # Some MCP servers expect an initialization message
        # This is optional and depends on the specific server implementation
        # For now, we'll skip it unless we encounter servers that require it
      end
    end
  end
end
