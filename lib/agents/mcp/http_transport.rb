# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Agents
  module MCP
    # HTTP transport for remote MCP servers
    class HttpTransport
      attr_reader :base_url, :headers, :timeout

      def initialize(options)
        @base_url = options[:url] || raise(ArgumentError, "url is required for HTTP transport")
        @headers = options[:headers] || {}
        @timeout = options[:timeout] || 30
        @use_sse = options[:use_sse] || false
        @uri = URI(@base_url)
        @http = nil
      end

      def connect
        @http = Net::HTTP.new(@uri.host, @uri.port)
        @http.use_ssl = @uri.scheme == "https"
        @http.read_timeout = @timeout
        @http.open_timeout = @timeout
        @http.start
      end

      def disconnect
        @http&.finish
        @http = nil
      end

      def send_request(request)
        # Determine endpoint based on method
        endpoint = case request[:method]
                   when "tools/list"
                     "/tools"
                   when "tools/call"
                     "/tools/call"
                   else
                     "/#{request[:method]}"
                   end

        if @use_sse
          send_sse_request(endpoint, request)
        else
          send_http_request(endpoint, request)
        end
      end

      private

      def send_http_request(endpoint, request)
        uri = URI.join(@base_url, endpoint)
        http_request = Net::HTTP::Post.new(uri)
        
        # Set headers
        http_request["Content-Type"] = "application/json"
        @headers.each { |key, value| http_request[key] = value }
        
        # Set body
        http_request.body = JSON.generate(request)

        response = @http.request(http_request)
        
        unless response.is_a?(Net::HTTPSuccess)
          raise ConnectionError, "HTTP request failed: #{response.code} #{response.message}"
        end

        begin
          JSON.parse(response.body)
        rescue JSON::ParserError => e
          raise ProtocolError, "Invalid JSON response: #{e.message}"
        end
      end

      def send_sse_request(endpoint, request)
        uri = URI.join(@base_url, endpoint)
        http_request = Net::HTTP::Post.new(uri)
        
        # Set headers for SSE
        http_request["Content-Type"] = "application/json"
        http_request["Accept"] = "text/event-stream"
        http_request["Cache-Control"] = "no-cache"
        @headers.each { |key, value| http_request[key] = value }
        
        # Set body
        http_request.body = JSON.generate(request)

        response = @http.request(http_request)
        
        unless response.is_a?(Net::HTTPSuccess)
          raise ConnectionError, "SSE request failed: #{response.code} #{response.message}"
        end

        parse_sse_response(response.body)
      end

      def parse_sse_response(body)
        events = []
        current_event = {}

        body.split("\n").each do |line|
          line = line.strip
          
          if line.empty?
            # Empty line indicates end of event
            if current_event[:data]
              events << current_event
              current_event = {}
            end
            next
          end

          if line.start_with?("data: ")
            data = line[6..-1] # Remove "data: " prefix
            current_event[:data] = data
          elsif line.start_with?("event: ")
            current_event[:event] = line[7..-1] # Remove "event: " prefix
          elsif line.start_with?("id: ")
            current_event[:id] = line[4..-1] # Remove "id: " prefix
          end
        end

        # Add final event if exists
        events << current_event if current_event[:data]

        # For tool calls, we typically want the final result
        # Find the event with actual JSON data
        data_event = events.find { |event| event[:data] && event[:data].start_with?("{") }
        
        if data_event
          begin
            JSON.parse(data_event[:data])
          rescue JSON::ParserError => e
            raise ProtocolError, "Invalid JSON in SSE data: #{e.message}"
          end
        else
          raise ProtocolError, "No valid JSON data found in SSE response"
        end
      end
    end
  end
end