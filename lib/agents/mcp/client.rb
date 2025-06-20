# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'
require 'open3'
require 'securerandom'

module Agents
  module MCP
    # Enhanced MCP Client for Ruby Agents SDK
    class Client
      attr_reader :server_url, :server_type, :capabilities

      def initialize(server_url_or_config)
        if server_url_or_config.is_a?(Hash)
          @config = server_url_or_config
          @server_url = @config['url']
          @server_type = @config['type'] || 'http'
        else
          @server_url = server_url_or_config
          @server_type = 'http'
          @config = {}
        end

        @capabilities = nil
        @session_id = nil
        @connected = false
      end

      # Connect to the MCP server and initialize session
      def connect
        case @server_type
        when 'http', 'https'
          connect_http
        when 'stdio'
          connect_stdio
        else
          raise "Unsupported MCP server type: #{@server_type}"
        end
      end

      # List available tools from the MCP server
      def list_tools
        ensure_connected
        
        request = {
          jsonrpc: "2.0",
          id: generate_id,
          method: "tools/list"
        }

        response = send_request(request)
        tools = response.dig("result", "tools") || []
        
        # Cache tool schemas for efficient access
        @tool_schemas = tools.each_with_object({}) do |tool, hash|
          hash[tool["name"]] = tool
        end
        
        tools
      end

      # Call a specific tool with parameters
      def call_tool(name, parameters = {})
        ensure_connected
        
        request = {
          jsonrpc: "2.0",
          id: generate_id,
          method: "tools/call",
          params: {
            name: name,
            arguments: parameters
          }
        }

        response = send_request(request)
        
        if response["error"]
          raise MCPError, "Tool call failed: #{response['error']['message']}"
        end

        result = response.dig("result")
        
        # Handle different response formats
        case result
        when Hash
          result["content"] || result["text"] || result.to_s
        when Array
          result.map { |item| item.is_a?(Hash) ? (item["content"] || item["text"] || item.to_s) : item.to_s }.join("\n")
        else
          result.to_s
        end
      end

      # Get server information and capabilities
      def server_info
        ensure_connected
        
        request = {
          jsonrpc: "2.0",
          id: generate_id,
          method: "initialize",
          params: {
            protocolVersion: "2024-11-05",
            capabilities: {
              tools: {}
            },
            clientInfo: {
              name: "ruby-agents-sdk",
              version: "1.0.0"
            }
          }
        }

        response = send_request(request)
        @capabilities = response.dig("result", "capabilities")
        response.dig("result")
      end

      # Check if server is healthy and responding
      def healthy?
        return false unless @connected
        
        begin
          ping_request = {
            jsonrpc: "2.0",
            id: generate_id,
            method: "ping"
          }
          
          response = send_request(ping_request)
          !response["error"]
        rescue => e
          puts "Health check failed: #{e.message}" if ENV['DEBUG']
          false
        end
      end

      # Disconnect from the server
      def disconnect
        @connected = false
        @session_id = nil
        
        if @stdio_process
          @stdio_process[:stdin].close rescue nil
          @stdio_process[:stdout].close rescue nil
          Process.kill('TERM', @stdio_process[:pid]) rescue nil
          @stdio_process = nil
        end
      end

      private

      def connect_http
        @uri = URI.parse(@server_url)
        
        # Test connection
        begin
          http = Net::HTTP.new(@uri.host, @uri.port)
          http.use_ssl = @uri.scheme == 'https'
          http.read_timeout = 5
          
          response = http.get(@uri.path.empty? ? '/' : @uri.path)
          @connected = true
          @session_id = SecureRandom.uuid
        rescue => e
          raise MCPError, "Failed to connect to MCP server: #{e.message}"
        end
      end

      def connect_stdio
        command = @config['command']
        args = @config['args'] || []
        
        raise MCPError, "No command specified for stdio MCP server" unless command
        
        begin
          stdin, stdout, stderr, wait_thread = Open3.popen3(command, *args)
          
          @stdio_process = {
            stdin: stdin,
            stdout: stdout,
            stderr: stderr,
            thread: wait_thread,
            pid: wait_thread.pid
          }
          
          @connected = true
          @session_id = SecureRandom.uuid
        rescue => e
          raise MCPError, "Failed to start stdio MCP server: #{e.message}"
        end
      end

      def ensure_connected
        connect unless @connected
      end

      def send_request(request)
        case @server_type
        when 'http', 'https'
          send_http_request(request)
        when 'stdio'
          send_stdio_request(request)
        end
      end

      def send_http_request(request)
        http = Net::HTTP.new(@uri.host, @uri.port)
        http.use_ssl = @uri.scheme == 'https'
        http.read_timeout = 30
        
        req = Net::HTTP::Post.new(@uri.path.empty? ? '/' : @uri.path)
        req['Content-Type'] = 'application/json'
        req['Authorization'] = @config['auth_token'] if @config['auth_token']
        req.body = request.to_json
        
        response = http.request(req)
        
        unless response.code.to_i == 200
          raise MCPError, "HTTP request failed: #{response.code} #{response.message}"
        end
        
        JSON.parse(response.body)
      rescue JSON::ParserError => e
        raise MCPError, "Invalid JSON response: #{e.message}"
      end

      def send_stdio_request(request)
        unless @stdio_process && @stdio_process[:stdin] && !@stdio_process[:stdin].closed?
          raise MCPError, "STDIO MCP server not available"
        end
        
        # Send request
        @stdio_process[:stdin].puts(request.to_json)
        @stdio_process[:stdin].flush
        
        # Read response
        response_line = @stdio_process[:stdout].gets
        unless response_line
          raise MCPError, "No response from STDIO MCP server"
        end
        
        JSON.parse(response_line.strip)
      rescue JSON::ParserError => e
        raise MCPError, "Invalid JSON response from STDIO server: #{e.message}"
      end

      def generate_id
        @request_id ||= 0
        @request_id += 1
      end
    end

    # MCP-specific error class
    class MCPError < Agents::Error; end
  end
end