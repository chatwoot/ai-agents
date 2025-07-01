# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require "timeout"
require "ipaddr"
require "openssl"

module Agents
  module MCP
    # HTTP transport for communicating with MCP servers via HTTP/HTTPS.
    # Supports both standard HTTP requests and Server-Sent Events (SSE) for streaming responses.
    # This transport is used when the MCP server is accessible via HTTP endpoints.
    #
    # @example Creating an HTTP transport
    #   transport = HttpTransport.new(
    #     url: "http://localhost:8000",
    #     headers: { "Authorization" => "Bearer token" },
    #     use_sse: false
    #   )
    #   transport.connect
    class HttpTransport
      attr_reader :base_url, :headers, :use_sse

      # Initialize the HTTP transport
      #
      # @param url [String] Base URL of the MCP server
      # @param headers [Hash<String,String>] HTTP headers to include in requests
      # @param use_sse [Boolean] Whether to use Server-Sent Events for streaming
      # @param verify_ssl [Boolean] Whether to verify SSL certificates (default: true)
      # @param allowed_origins [Array<String>] Allowed origins for DNS rebinding protection
      def initialize(url:, headers: {}, use_sse: false, verify_ssl: true, allowed_origins: [])
        @url = url.chomp("/") # Remove trailing slash for consistency
        @base_url = @url
        @headers = headers.dup
        @use_sse = use_sse
        @verify_ssl = verify_ssl
        @allowed_origins = allowed_origins
        @connected = false
        @request_id = 0
        @mutex = Mutex.new # Thread safety for request IDs

        # Security: Add User-Agent and validate URL
        validate_url!
        @headers["User-Agent"] ||= "ruby-agents-mcp/#{Agents::VERSION}"
        @headers["Accept"] = "application/json"
      end

      # Connect to the MCP server (lightweight for HTTP)
      #
      # @raise [ConnectionError] If server is not reachable
      def connect
        return if @connected

        begin
          # Test connection with health endpoint if available, otherwise root
          test_endpoints = ["/health", "/"]

          test_endpoints.each do |endpoint|
            uri = URI.join(@base_url, endpoint)
            http = create_http_client(uri)

            request = Net::HTTP::Get.new(uri)
            @headers.each { |k, v| request[k] = v }

            http.request(request)
            # Accept any response that indicates server is running
            # (even 404 is fine, means server is up)

            @connected = true
            return
          rescue StandardError => e
            # Try next endpoint
            next if endpoint != test_endpoints.last

            raise e
          end
        rescue Timeout::Error => e
          raise ConnectionError, "Request timeout: #{e.message}"
        rescue StandardError => e
          raise ConnectionError, "Failed to connect to MCP server at #{@base_url}: #{e.message}"
        end
      end

      # Check if transport is connected
      #
      # @return [Boolean] True if connected
      def connected?
        @connected
      end

      # Call an MCP method and return the result
      #
      # @param method [String] The MCP method name (e.g., "tools/list", "tools/call")
      # @param params [Hash] Parameters for the method call
      # @return [Hash] The result from the MCP server
      # @raise [ConnectionError] If not connected or communication fails
      # @raise [ProtocolError] If response parsing fails
      def call(method, params = {})
        connect unless connected?

        # Transform parameter keys to strings for JSON compatibility
        string_params = deep_transform_keys(params)

        request = {
          "jsonrpc" => "2.0",
          "method" => method,
          "params" => string_params
        }

        response = send_request(request)
        
        # Return the result - nil if no result key (consistent with STDIO transport)
        response.is_a?(Hash) ? response["result"] : response
      end

      # Send a JSON-RPC request via HTTP
      #
      # @param request [Hash] The JSON-RPC request hash
      # @return [Hash] The parsed JSON response
      # @raise [ConnectionError] If HTTP request fails
      # @raise [ProtocolError] If response parsing fails
      # @raise [ServerError] If server returns an error
      def send_request(request)
        raise ConnectionError, "Not connected" unless connected?

        @mutex.synchronize { @request_id += 1 }
        request_with_id = request.merge("id" => @request_id)

        # Try MCP endpoints in order of preference
        # 1. Standard MCP HTTP endpoint (most common)
        # 2. Method-specific REST endpoints (for compatibility)
        send_mcp_request(request_with_id)
      end

      # Disconnect from the MCP server (no-op for HTTP)
      def disconnect
        @connected = false
      end

      # Close the connection (alias for disconnect)
      def close
        disconnect
      end

      # Check if connected
      def connected?
        @connected
      end

      private

      # Deep transform hash keys to strings for JSON compatibility
      #
      # @param obj [Object] The object to transform
      # @return [Object] The transformed object
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

      # Send a generic MCP request to /mcp/call endpoint
      #
      # @param request [Hash] The JSON-RPC request with ID
      # @return [Hash] Parsed response
      def send_mcp_request(request)
        method = request["method"]
        
        # Try different endpoint patterns based on method
        endpoint_patterns = case method
                           when "tools/list"
                             ["/tools", "/mcp", "/"]
                           when "tools/call"
                             ["/tools/call", "/mcp", "/"]
                           when "resources/list"
                             ["/resources", "/mcp", "/"]
                           when "resources/read" 
                             ["/resources/read", "/mcp", "/"]
                           when "prompts/list"
                             ["/prompts", "/mcp", "/"]
                           when "prompts/get"
                             ["/prompts/get", "/mcp", "/"]
                           else
                             ["/mcp", "/"]
                           end

        last_error = nil
        
        endpoint_patterns.each do |endpoint_path|
          begin
            return try_endpoint(request, endpoint_path, method)
          rescue ConnectionError => e
            last_error = e
            # Try next endpoint
            next
          end
        end
        
        # If all endpoints failed, raise the last error
        raise last_error || ConnectionError.new("All MCP endpoints failed")
      end

      # Try a specific endpoint with the request
      #
      # @param request [Hash] The JSON-RPC request
      # @param endpoint_path [String] The endpoint path to try
      # @param method [String] The original method name
      # @return [Hash] Parsed response
      def try_endpoint(request, endpoint_path, method)
        base_uri = URI.parse(@base_url)
        full_path = File.join(base_uri.path, endpoint_path).gsub(/\/+/, "/") # Remove duplicate slashes
        full_uri = base_uri.dup
        full_uri.path = full_path

        http = create_http_client(full_uri)
        
        # Determine HTTP method and adjust request based on endpoint
        if endpoint_path.include?("/mcp")
          # Standard MCP JSON-RPC endpoint - use POST with full request
          http_request = Net::HTTP::Post.new(full_path)
          http_request["Content-Type"] = "application/json"
          http_request.body = JSON.generate(request)
        elsif method == "tools/list" && endpoint_path == "/tools"
          # REST-style GET for tools list
          http_request = Net::HTTP::Get.new(full_path)
        elsif method == "tools/call" && endpoint_path == "/tools/call"
          # REST-style POST for tool calls
          http_request = Net::HTTP::Post.new(full_path)
          http_request["Content-Type"] = "application/json"
          http_request.body = JSON.generate(request)
        else
          # Default to POST with JSON-RPC
          http_request = Net::HTTP::Post.new(full_path)
          http_request["Content-Type"] = "application/json"
          http_request.body = JSON.generate(request)
        end

        # Add headers
        @headers.each { |k, v| http_request[k] = v }

        begin
          response = http.request(http_request)
          handle_http_response(response)
        rescue Errno::ECONNREFUSED => e
          raise ConnectionError, "Failed to connect to MCP server at #{@base_url}: #{e.message}"
        rescue Timeout::Error => e
          raise ConnectionError, "Request timeout: #{e.message}"
        rescue ProtocolError, ServerError
          # Re-raise protocol and server errors
          raise
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

          # Handle JSON-RPC error responses
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

        # Basic scheme validation
        unless %w[http https].include?(uri.scheme)
          raise ConnectionError, "Unsupported URL scheme: #{uri.scheme}. Only HTTP and HTTPS are allowed."
        end

        # DNS rebinding protection: validate against allowed origins if specified
        if @allowed_origins.any?
          origin = "#{uri.scheme}://#{uri.host}:#{uri.port}"
          unless @allowed_origins.include?(origin)
            raise ConnectionError, "URL origin #{origin} not in allowed origins list"
          end
        end

        # Additional security: prevent localhost/private network access in production
        # Only if allowed_origins is specified (indicates security-conscious setup)
        return unless @allowed_origins.any? && private_network_address?(uri.host)
        return if @allowed_origins.any? { |origin| URI.parse(origin).host == uri.host }

        raise ConnectionError, "Private network access not explicitly allowed: #{uri.host}"
      end

      # Check if host is a private network address
      #
      # @param host [String] The hostname to check
      # @return [Boolean] True if host is private network
      def private_network_address?(host)
        # Handle localhost variants
        return true if ["localhost", "127.0.0.1", "::1"].include?(host)

        # Check for private IP ranges
        begin
          addr = IPAddr.new(host)
          private_ranges = [
            IPAddr.new("10.0.0.0/8"),
            IPAddr.new("172.16.0.0/12"),
            IPAddr.new("192.168.0.0/16"),
            IPAddr.new("169.254.0.0/16"), # Link-local
            IPAddr.new("fc00::/7")        # IPv6 private
          ]
          private_ranges.any? { |range| range.include?(addr) }
        rescue IPAddr::InvalidAddressError
          false # Not an IP address, could be hostname
        end
      end

      # Create HTTP client for given URI
      #
      # @param uri [URI] The URI to connect to
      # @return [Net::HTTP] Configured HTTP client
      def create_http_client(uri)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == "https")

        # Security: SSL verification (can be disabled for development)
        if uri.scheme == "https"
          http.verify_mode = @verify_ssl ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE
          http.ca_file = ENV["SSL_CA_FILE"] if ENV["SSL_CA_FILE"]
          http.ca_path = ENV["SSL_CA_PATH"] if ENV["SSL_CA_PATH"]
        end

        # Reasonable timeouts
        http.read_timeout = 30
        http.open_timeout = 10
        http.write_timeout = 30 if http.respond_to?(:write_timeout=)

        http
      end
    end
  end
end
