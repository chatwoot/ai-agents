# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

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
      def initialize(url:, headers: {}, use_sse: false)
        @base_url = url
        @headers = headers
        @use_sse = use_sse
        @connected = false
        @request_id = 0
      end

      # Connect to the MCP server (lightweight for HTTP)
      #
      # @raise [ConnectionError] If server is not reachable
      def connect
        return if @connected

        begin
          # Test connection with a simple request
          uri = URI.join(@base_url, "/")
          http = create_http_client(uri)
          
          # Try a HEAD request to test connectivity
          request = Net::HTTP::Head.new(uri)
          @headers.each { |k, v| request[k] = v }
          
          response = http.request(request)
          # Accept any response that indicates server is running
          # (even 404 is fine, means server is up)
          
          @connected = true
        rescue => e
          raise ConnectionError, "Failed to connect to MCP server at #{@base_url}: #{e.message}"
        end
      end

      # Check if transport is connected
      #
      # @return [Boolean] True if connected
      def connected?
        @connected
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

        @request_id += 1
        request_with_id = request.merge("id" => @request_id)

        case request["method"]
        when "tools/list"
          send_tools_list_request
        when "tools/call"
          send_tools_call_request(request_with_id)
        else
          raise ProtocolError, "Unsupported method: #{request['method']}"
        end
      end

      # Disconnect from the MCP server (no-op for HTTP)
      def disconnect
        @connected = false
      end

      private

      # Create HTTP client for given URI
      #
      # @param uri [URI] The URI to connect to
      # @return [Net::HTTP] Configured HTTP client
      def create_http_client(uri)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == 'https')
        http.read_timeout = 30
        http.open_timeout = 10
        http
      end

      # Send GET request to list tools
      #
      # @return [Hash] Parsed response containing tools list
      def send_tools_list_request
        uri = URI.join(@base_url, "/tools")
        http = create_http_client(uri)
        
        request = Net::HTTP::Get.new(uri)
        @headers.each { |k, v| request[k] = v }
        request['Accept'] = 'application/json'

        response = http.request(request)
        
        unless response.code.to_i == 200
          raise ServerError, "HTTP #{response.code}: #{response.message}"
        end

        begin
          JSON.parse(response.body)
        rescue JSON::ParserError => e
          raise ProtocolError, "Invalid JSON response: #{e.message}"
        end
      end

      # Send POST request to call a tool
      #
      # @param request_data [Hash] The JSON-RPC request with ID
      # @return [Hash] Parsed response containing tool result
      def send_tools_call_request(request_data)
        if @use_sse
          send_sse_request(request_data)
        else
          send_standard_request(request_data)
        end
      end

      # Send standard HTTP POST request
      #
      # @param request_data [Hash] The JSON-RPC request
      # @return [Hash] Parsed response
      def send_standard_request(request_data)
        uri = URI.join(@base_url, "/tools/call")
        http = create_http_client(uri)
        
        request = Net::HTTP::Post.new(uri)
        @headers.each { |k, v| request[k] = v }
        request['Content-Type'] = 'application/json'
        request['Accept'] = 'application/json'
        request.body = request_data.to_json

        response = http.request(request)
        
        unless response.code.to_i == 200
          raise ServerError, "HTTP #{response.code}: #{response.message}"
        end

        begin
          JSON.parse(response.body)
        rescue JSON::ParserError => e
          raise ProtocolError, "Invalid JSON response: #{e.message}"
        end
      end

      # Send request using Server-Sent Events
      #
      # @param request_data [Hash] The JSON-RPC request
      # @return [Hash] Parsed response from SSE stream
      def send_sse_request(request_data)
        uri = URI.join(@base_url, "/tools/call")
        http = create_http_client(uri)
        
        request = Net::HTTP::Post.new(uri)
        @headers.each { |k, v| request[k] = v }
        request['Content-Type'] = 'application/json'
        request['Accept'] = 'text/event-stream'
        request.body = request_data.to_json

        content_parts = []
        is_error = false
        
        http.request(request) do |response|
          unless response.code.to_i == 200
            raise ServerError, "HTTP #{response.code}: #{response.message}"
          end

          buffer = ""
          response.read_body do |chunk|
            buffer += chunk
            
            # Process complete SSE events
            while buffer.include?("\n\n")
              event, buffer = buffer.split("\n\n", 2)
              process_sse_event(event, content_parts)
            end
          end
          
          # Process any remaining event
          if !buffer.strip.empty?
            process_sse_event(buffer, content_parts)
          end
        end

        # Return formatted response
        {
          "result" => {
            "content" => content_parts,
            "isError" => is_error
          }
        }
      end

      # Process a single SSE event
      #
      # @param event [String] Raw SSE event string
      # @param content_parts [Array] Array to accumulate content parts
      def process_sse_event(event, content_parts)
        event.split("\n").each do |line|
          if line.start_with?("data: ")
            data = line[6..-1] # Remove "data: " prefix
            next if data.strip.empty? || data == "[DONE]"
            
            begin
              parsed = JSON.parse(data)
              if parsed.is_a?(Hash) && parsed["content"]
                content_parts.concat(Array(parsed["content"]))
              elsif parsed.is_a?(Hash) && parsed["type"] == "text"
                content_parts << parsed
              end
            rescue JSON::ParserError
              # Skip invalid JSON data
            end
          end
        end
      end
    end
  end
end