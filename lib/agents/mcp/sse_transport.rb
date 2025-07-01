# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require "timeout"
require "ipaddr"
require "openssl"

module Agents
  module MCP
    # Server-Sent Events (SSE) transport for communicating with MCP servers.
    # Provides streaming communication via SSE with fallback to standard HTTP.
    # This transport is particularly useful for long-running connections and real-time updates.
    #
    # @example Creating an SSE transport
    #   transport = SseTransport.new(
    #     url: "http://localhost:8000/sse",
          #     headers: { "X-Custom-Header" => "value" },
    #     verify_ssl: true,
    #     allowed_origins: ["http://localhost:8000"]
    #   )
    #   transport.connect
    class SseTransport
      attr_reader :base_url, :headers, :verify_ssl, :allowed_origins

      # Initialize the SSE transport
      #
      # @param url [String] Base URL of the MCP server SSE endpoint
      # @param headers [Hash<String,String>] HTTP headers to include in requests
      # @param verify_ssl [Boolean] Whether to verify SSL certificates (default: true)
      # @param allowed_origins [Array<String>] Allowed origins for DNS rebinding protection
      # @param reconnect_time [Integer] Time to wait before reconnecting (default: 3000ms)
      def initialize(url:, headers: {}, verify_ssl: true, allowed_origins: [], reconnect_time: 3000)
        @url = url.chomp("/")
        @base_url = @url
        @headers = headers.dup
        @verify_ssl = verify_ssl
        @allowed_origins = allowed_origins
        @reconnect_time = reconnect_time
        @connected = false
        @request_id = 0
        @mutex = Mutex.new
        @sse_thread = nil
        @stop_requested = false
        @message_handlers = []
        @error_handlers = []
        @close_handlers = []

        # Security: Add User-Agent and validate URL
        validate_url!
        @headers["User-Agent"] ||= "ruby-agents-mcp-sse/#{Agents::VERSION}"
        @headers["Accept"] = "text/event-stream, application/json"
        @headers["Cache-Control"] = "no-cache"
      end

      # Connect to the SSE endpoint
      #
      # @raise [ConnectionError] If server is not reachable
      def connect
        return if @connected

        @stop_requested = false
        start_sse_connection
        @connected = true
      end

      # Check if transport is connected
      #
      # @return [Boolean] True if connected
      def connected?
        @connected && @sse_thread&.alive?
      end

      # Call an MCP method and return the result
      #
      # @param method [String] The MCP method name
      # @param params [Hash] Parameters for the method call
      # @return [Hash] The result from the MCP server
      def call(method, params = {})
        connect unless connected?

        string_params = deep_transform_keys(params)

        request = {
          "jsonrpc" => "2.0",
          "method" => method,
          "params" => string_params
        }

        response = send_request(request)
        response.dig("result")
      end

      # Send a JSON-RPC request via SSE/HTTP hybrid
      #
      # @param request [Hash] The JSON-RPC request hash
      # @return [Hash] The parsed JSON response
      def send_request(request)
        raise ConnectionError, "Not connected" unless connected?

        request_id = nil
        @mutex.synchronize { request_id = @request_id += 1 }

        request_with_id = { "jsonrpc" => request["jsonrpc"], "id" => request_id }.merge(request.except("jsonrpc"))

        # For SSE, we typically send via HTTP POST and receive via SSE stream
        send_http_request(request_with_id)
      end

      # Add message handler for SSE events
      #
      # @param block [Proc] Block to handle messages
      def on_message(&block)
        @message_handlers << block
      end

      # Add error handler for SSE errors
      #
      # @param block [Proc] Block to handle errors
      def on_error(&block)
        @error_handlers << block
      end

      # Add close handler for SSE disconnection
      #
      # @param block [Proc] Block to handle close events
      def on_close(&block)
        @close_handlers << block
      end

      # Disconnect from the SSE endpoint
      def disconnect
        @stop_requested = true
        @connected = false

        if @sse_thread&.alive?
          @sse_thread.kill
          @sse_thread.join(5) # Wait up to 5 seconds
        end

        @close_handlers.each { |handler| handler.call }
      end

      # Close the connection (alias for disconnect)
      def close
        disconnect
      end

      private

      # Deep transform hash keys to strings for JSON compatibility
      def deep_transform_keys(obj)
        case obj
        when Hash
          obj.transform_keys(&:to_s).transform_values { |v| deep_transform_keys(v) }
        when Array
          obj.map { |v| deep_transform_keys(v) }
        else
          obj
        end
      end

      # Start SSE connection in background thread
      def start_sse_connection
        @sse_thread = Thread.new do
          connect_sse_stream
        rescue StandardError => e
          @error_handlers.each { |handler| handler.call(e) }
          # Auto-reconnect logic
          unless @stop_requested
            sleep(@reconnect_time / 1000.0)
            retry unless @stop_requested
          end
        end
      end

      # Connect to SSE stream and process events
      def connect_sse_stream
        uri = URI.join(@base_url, "/sse")
        http = create_http_client(uri)

        request = Net::HTTP::Get.new(uri)
        @headers.each { |k, v| request[k] = v }

        http.request(request) do |response|
          unless response.code.start_with?("2")
            raise ConnectionError, "SSE connection failed: HTTP #{response.code}: #{response.message}"
          end

          buffer = ""
          response.read_body do |chunk|
            break if @stop_requested

            buffer += chunk
            lines = buffer.split("\n")
            buffer = lines.pop || "" # Keep incomplete line in buffer

            lines.each do |line|
              process_sse_line(line.strip)
            end
          end
        end
      end

      # Process individual SSE lines
      #
      # @param line [String] SSE line to process
      def process_sse_line(line)
        return if line.empty? || line.start_with?(":") # Skip empty lines and comments

        if line.start_with?("data: ")
          data = line[6..-1] # Remove 'data: ' prefix

          begin
            message = JSON.parse(data)
            @message_handlers.each { |handler| handler.call(message) }
          rescue JSON::ParserError
            # Ignore non-JSON data lines (could be heartbeat, etc.)
          end
        elsif line.start_with?("event: ")
          # Handle custom event types if needed
        elsif line.start_with?("retry: ")
          # Update reconnection time if server suggests it
          @reconnect_time = line[7..-1].to_i
        end
      end

      # Send HTTP request for JSON-RPC calls
      #
      # @param request [Hash] The JSON-RPC request
      # @return [Hash] Parsed response
      def send_http_request(request)
        uri = URI.join(@base_url, "/mcp/call")
        http = create_http_client(uri)

        http_request = Net::HTTP::Post.new(uri)
        http_request["Content-Type"] = "application/json"
        @headers.each { |k, v| http_request[k] = v unless k == "Accept" } # Don't send SSE Accept header
        http_request.body = JSON.generate(request)

        begin
          response = http.request(http_request)
          handle_http_response(response)
        rescue StandardError => e
          raise ConnectionError, "HTTP request failed: #{e.message}"
        end
      end

      # Handle HTTP response and parse JSON
      #
      # @param response [Net::HTTPResponse] The HTTP response
      # @return [Hash] Parsed JSON response
      def handle_http_response(response)
        raise ConnectionError, "HTTP #{response.code}: #{response.message}" unless response.code.start_with?("2")

        raise ProtocolError, "Empty response from server" if response.body.nil? || response.body.strip.empty?

        begin
          parsed = JSON.parse(response.body)

          if parsed.key?("error")
            error_info = parsed["error"]
            message = error_info["message"] || "Unknown error"
            raise ServerError, message
          end

          parsed
        rescue JSON::ParserError => e
          raise ProtocolError, "Invalid JSON response: #{e.message}"
        end
      end

      # Validate URL for security (DNS rebinding protection)
      #
      # @raise [ConnectionError] If URL is not allowed
      def validate_url!
        uri = URI.parse(@url)

        unless %w[http https].include?(uri.scheme)
          raise ConnectionError, "Unsupported URL scheme: #{uri.scheme}. Only HTTP and HTTPS are allowed."
        end

        if @allowed_origins.any?
          origin = "#{uri.scheme}://#{uri.host}:#{uri.port}"
          unless @allowed_origins.include?(origin)
            raise ConnectionError, "URL origin #{origin} not in allowed origins list"
          end
        end

        return unless @allowed_origins.any? && private_network_address?(uri.host)
        return if @allowed_origins.any? { |origin| URI.parse(origin).host == uri.host }

        raise ConnectionError, "Private network access not explicitly allowed: #{uri.host}"
      end

      # Check if host is a private network address
      #
      # @param host [String] The hostname to check
      # @return [Boolean] True if host is private network
      def private_network_address?(host)
        return true if ["localhost", "127.0.0.1", "::1"].include?(host)

        begin
          addr = IPAddr.new(host)
          private_ranges = [
            IPAddr.new("10.0.0.0/8"),
            IPAddr.new("172.16.0.0/12"),
            IPAddr.new("192.168.0.0/16"),
            IPAddr.new("169.254.0.0/16"),
            IPAddr.new("fc00::/7")
          ]
          private_ranges.any? { |range| range.include?(addr) }
        rescue IPAddr::InvalidAddressError
          false
        end
      end

      # Create HTTP client for given URI
      #
      # @param uri [URI] The URI to connect to
      # @return [Net::HTTP] Configured HTTP client
      def create_http_client(uri)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == "https")

        if uri.scheme == "https"
          http.verify_mode = @verify_ssl ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE
          http.ca_file = ENV["SSL_CA_FILE"] if ENV["SSL_CA_FILE"]
          http.ca_path = ENV["SSL_CA_PATH"] if ENV["SSL_CA_PATH"]
        end

        http.read_timeout = 30
        http.open_timeout = 10
        http.write_timeout = 30 if http.respond_to?(:write_timeout=)

        http
      end
    end
  end
end
