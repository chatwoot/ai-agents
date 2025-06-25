# frozen_string_literal: true

# MCP (Model Context Protocol) support for Ruby Agents SDK
# This module provides MCP client functionality to connect Ruby agents
# to external MCP servers, enabling dynamic tool discovery and execution.

require "json"
require "net/http"
require "uri"
require "open3"
require "securerandom"

module Agents
  module MCP
    class Error < Agents::Error; end
    class ConnectionError < Error; end
    class ProtocolError < Error; end
    class ServerError < Error; end

    # MCP Client - manages connections to MCP servers
    class Client
      attr_reader :name, :connected, :transport_type, :tools_cache, :include_tools, :exclude_tools

      def initialize(name:, include_tools: nil, exclude_tools: nil, **options)
        @name = name
        @options = options
        @connected = false
        @tools_cache = nil
        @cache_enabled = options.fetch(:cache_tools, false)
        @transport = nil
        @transport_type = determine_transport_type(options)
        
        # Tool filtering configuration
        @include_tools = normalize_tool_filter(include_tools)
        @exclude_tools = normalize_tool_filter(exclude_tools)
      end

      # Connect to the MCP server
      def connect
        return if @connected

        @transport = create_transport
        @transport.connect
        @connected = true
      end

      # Disconnect from the MCP server
      def disconnect
        return unless @connected

        @transport&.disconnect
        @connected = false
        @tools_cache = nil
      end

      # List available tools from the MCP server
      def list_tools(force_refresh: false)
        ensure_connected!

        return @tools_cache if @cache_enabled && @tools_cache && !force_refresh

        response = @transport.send_request({
                                             jsonrpc: "2.0",
                                             id: generate_request_id,
                                             method: "tools/list",
                                             params: {}
                                           })

        tools = parse_tools_response(response)
        filtered_tools = apply_tool_filters(tools)
        @tools_cache = filtered_tools if @cache_enabled
        filtered_tools
      end

      # Call a specific tool on the MCP server
      def call_tool(name, arguments = {})
        ensure_connected!

        response = @transport.send_request({
                                             jsonrpc: "2.0",
                                             id: generate_request_id,
                                             method: "tools/call",
                                             params: {
                                               name: name,
                                               arguments: arguments
                                             }
                                           })

        parse_tool_call_response(response)
      end

      # Invalidate the tools cache
      def invalidate_tools_cache
        @tools_cache = nil
      end

      # Check if client is connected
      def connected?
        @connected
      end

      private

      def determine_transport_type(options)
        if options[:command] || options[:args]
          :stdio
        elsif options[:url]
          url = URI(options[:url])
          case url.scheme
          when "http", "https"
            :http
          else
            raise ArgumentError, "Unsupported URL scheme: #{url.scheme}"
          end
        else
          raise ArgumentError, "Must specify either command/args for stdio or url for HTTP transport"
        end
      end

      def create_transport
        case @transport_type
        when :stdio
          StdioTransport.new(@options)
        when :http
          HttpTransport.new(@options)
        else
          raise ArgumentError, "Unknown transport type: #{@transport_type}"
        end
      end

      def ensure_connected!
        raise ConnectionError, "Not connected to MCP server" unless @connected
      end

      def generate_request_id
        SecureRandom.hex(8)
      end

      def parse_tools_response(response)
        raise ServerError, "Server error: #{response["error"]["message"]}" if response["error"]

        tools_data = response.dig("result", "tools") || []
        tools_data.map { |tool_data| Tool.create_from_mcp_data(tool_data, client: self) }
      end

      # Normalize tool filter input to consistent format
      # @param filter [String, Array, Regexp, nil] Tool filter specification
      # @return [Array] Normalized filter array
      def normalize_tool_filter(filter)
        return nil if filter.nil?
        return [filter] unless filter.is_a?(Array)
        filter
      end

      # Apply include/exclude filters to tools list
      # @param tools [Array<Tool>] List of tools to filter
      # @return [Array<Tool>] Filtered tools list
      def apply_tool_filters(tools)
        filtered_tools = tools
        
        # Apply include filter if specified
        if @include_tools
          filtered_tools = filtered_tools.select do |tool|
            matches_any_filter?(tool.name, @include_tools)
          end
        end
        
        # Apply exclude filter if specified
        if @exclude_tools
          filtered_tools = filtered_tools.reject do |tool|
            matches_any_filter?(tool.name, @exclude_tools)
          end
        end
        
        filtered_tools
      end
      
      # Check if a tool name matches any of the given filters
      # @param tool_name [String] The tool name to check
      # @param filters [Array] Array of filter patterns (String, Regexp)
      # @return [Boolean] True if the tool name matches any filter
      def matches_any_filter?(tool_name, filters)
        filters.any? do |filter|
          case filter
          when String
            # Support glob-like patterns
            if filter.include?('*')
              # Convert glob pattern to regex
              regex_pattern = Regexp.escape(filter).gsub('\*', '.*')
              tool_name =~ /^#{regex_pattern}$/
            else
              tool_name == filter
            end
          when Regexp
            tool_name =~ filter
          else
            tool_name == filter.to_s
          end
        end
      end

      def parse_tool_call_response(response)
        raise ServerError, "Tool call error: #{response["error"]["message"]}" if response["error"]

        result = response["result"]
        if result["isError"]
          raise ServerError, "Tool execution error: #{result["content"]&.first&.dig("text") || "Unknown error"}"
        end

        # Extract content from MCP response format
        content = result["content"] || []
        if content.length == 1 && content.first["type"] == "text"
          content.first["text"]
        else
          ToolResult.new(content)
        end
      end
    end

    # MCP Tool representation - dynamically creates tool classes
    class Tool < Agents::Tool
      attr_reader :mcp_name, :mcp_description, :input_schema, :client

      def self.create_from_mcp_data(tool_data, client:)
        # Create a dynamic class for this specific MCP tool
        tool_class = Class.new(self) do
          # Set up the tool description and name
          description(tool_data["description"] || "MCP tool: #{tool_data["name"]}")

          # Set up parameters from schema
          properties = tool_data.dig("inputSchema", "properties") || {}
          required_props = tool_data.dig("inputSchema", "required") || []

          properties.each do |prop_name, prop_schema|
            # Handle JSON schema references
            if prop_schema["$ref"]
              # For now, assume referenced types are the same as account_id (integer)
              # A more complete implementation would resolve the reference
              param_type = Integer
              param_desc = ""
            else
              param_type = case prop_schema["type"]
                           when "string" then String
                           when "integer" then Integer
                           when "number" then Float
                           when "boolean" then TrueClass
                           when "array" then Array
                           when "object" then Hash
                           else String
                           end
              param_desc = prop_schema["description"] || ""
              if prop_schema["enum"]
                param_desc += " (Options: #{prop_schema["enum"].join(", ")})"
              end
            end

            is_required = required_props.include?(prop_name)

            param(prop_name.to_sym, param_type, param_desc, required: is_required)
          end

          define_method :initialize do
            @mcp_name = tool_data["name"]
            @mcp_description = tool_data["description"]
            @input_schema = tool_data["inputSchema"] || {}
            @client = client
            super()
          end

          define_method :perform do |**args|
            # Remove context from args before sending to MCP server
            mcp_args = args.dup
            mcp_args.delete(:context)
            @client.call_tool(@mcp_name, mcp_args)
          end

          define_method :name do
            @mcp_name
          end

          define_method :description do
            @mcp_description
          end
        end

        # Create instance of the dynamic class
        tool_class.new
      end

      def initialize
        super()
      end
    end

    # Wrapper for complex MCP tool results
    class ToolResult
      attr_reader :content

      def initialize(content)
        @content = content
      end

      def to_s
        text_content = @content.select { |item| item["type"] == "text" }
                               .map { |item| item["text"] }
                               .join("\n")
        text_content.empty? ? @content.to_json : text_content
      end

      def text_content
        @content.select { |item| item["type"] == "text" }
                .map { |item| item["text"] }
      end

      def image_content
        @content.select { |item| item["type"] == "image" }
      end

      def images?
        @content.any? { |item| item["type"] == "image" }
      end
    end
  end
end

# Monkey-patch RubyLLM to add array items for all tools (not just MCP)
# This fixes OpenAI validation that requires array parameters to have items
begin
  require "ruby_llm/providers/openai/tools"
  
  module RubyLLM
    module Providers
      module OpenAI
        module Tools
          # Override param_schema to add items for array types
          def param_schema(param)
            schema = {
              type: param.type,
              description: param.description
            }.compact
            
            # Add items for array types to fix OpenAI validation
            if param.type == "array"
              schema[:items] = { type: "string" }
            end
            
            schema
          end
        end
      end
    end
  end
rescue LoadError
  # RubyLLM not available, skip monkey-patch
end
