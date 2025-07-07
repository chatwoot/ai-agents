# frozen_string_literal: true

require "set"
require "rbconfig"

module Agents
  module MCP
    # MCP Client provides the interface for connecting to and communicating with
    # Model Context Protocol servers. It handles connection management, tool discovery,
    # filtering, and tool execution while abstracting away the transport details.
    #
    # The client supports both STDIO (subprocess) and HTTP transports, automatically
    # determining which to use based on the initialization parameters provided.
    #
    # @example STDIO connection to filesystem server
    #   client = Client.new(
    #     name: "filesystem",
    #     command: "npx",
    #     args: ["-y", "@modelcontextprotocol/server-filesystem", "."],
    #     include_tools: ["read_file", "write_file"],
    #     exclude_tools: ["delete_file"]
    #   )
    #   client.connect
    #   tools = client.list_tools
    #
    # @example HTTP connection to API server
    #   client = Client.new(
    #     name: "api_server",
    #     url: "http://localhost:8000",
          #     headers: { "X-Custom-Header" => "value" }
    #   )
    #   client.connect
    #   result = client.call_tool("get_users", {})
    class Client
      attr_reader :name, :include_tools, :exclude_tools, :transport

      # Initialize a new MCP client
      #
      # @param name [String] Identifier for this client (for logging/debugging)
      # @param include_tools [String, Array<String>, Regexp, Array<Regexp>, nil]
      #   Whitelist patterns for tool names. If nil, all tools are included.
      # @param exclude_tools [String, Array<String>, Regexp, Array<Regexp>, nil]
      #   Blacklist patterns for tool names. If nil, no tools are excluded.
      # @param options [Hash] Transport-specific options
      # @option options [String] :command Command for STDIO transport
      # @option options [Array<String>] :args Arguments for STDIO command
      # @option options [Hash<String,String>] :env Environment variables for STDIO
      # @option options [String] :url Base URL for HTTP transport
      # @option options [Hash<String,String>] :headers HTTP headers
      # @option options [Boolean] :use_sse Whether to use Server-Sent Events for HTTP
      # @option options [String] :transport_type Transport type: 'stdio', 'http', 'sse' (default: auto-detect)
      # @option options [Boolean] :verify_ssl Whether to verify SSL certificates (default: true)
      # @option options [Array<String>] :allowed_origins Allowed origins for DNS rebinding protection

      def initialize(name: nil, include_tools: nil, exclude_tools: nil, **options)
        raise ArgumentError, "name is required" if name.nil? || name.empty?

        @name = name
        @include_tools = normalize_filter(include_tools)
        @exclude_tools = normalize_filter(exclude_tools)
        @options = options
        @transport = determine_transport(options)
        @connected = false
        @tools_cache = nil
        @mutex = Mutex.new # Protect tools cache and connection state
      end

      # Connect to the MCP server
      #
      # @raise [ConnectionError] If connection fails
      def connect
        return if connected?

        begin
          # Actually connect the transport
          @transport.connect
          @connected = true
        rescue StandardError => e
          raise ConnectionError, "Failed to connect to MCP server '#{@name}': #{e.message}"
        end
      end

      # Check if client is connected to the MCP server
      #
      # @return [Boolean] True if connected
      def connected?
        @connected
      end

      # List available tools from the MCP server with filtering applied
      #
      # @param refresh [Boolean] Whether to refresh the cache
      # @return [Array<Agents::MCP::Tool>] Array of available tool instances
      # @raise [ConnectionError] If not connected or communication fails
      def list_tools(refresh: false)
        connect unless connected?

        @mutex.synchronize do
          # Return cached tools unless refresh requested
          return @tools_cache.dup if @tools_cache && !refresh

          begin
            # Get tools from MCP server
            response = @transport.call("tools/list", {})

            # Extract tools from response
            tools_data = extract_tools_from_response(response)

            # Apply filtering
            filtered_tools = filter_tools(tools_data)

            # Create tool instances
            tool_instances = create_tool_instances(filtered_tools)

            # Cache the results
            @tools_cache = tool_instances

            tool_instances.dup
          rescue StandardError => e
            # Log error but don't raise - allow agent to continue without MCP tools
            warn "Failed to list tools from MCP client '#{@name}': #{e.message}"
            @tools_cache = []
            []
          end
        end
      end

      # Call a specific tool on the MCP server
      #
      # @param tool_name [String] Name of the tool to call
      # @param arguments [Hash] Arguments to pass to the tool
      # @return [ToolResult, String] Tool result or simple string response
      # @raise [ConnectionError] If not connected or communication fails
      # @raise [ServerError] If server returns an error
      def call_tool(tool_name, arguments = {})
        connect unless connected?

        begin
          response = @transport.call("tools/call", {
                                       "name" => tool_name,
                                       "arguments" => arguments
                                     })

          # Convert response to ToolResult
          result = ToolResult.from_mcp_response(response)

          # Check if the result represents an error
          raise ServerError, result.to_s if result.error?

          result
        rescue StandardError => e
          raise ServerError, "Failed to call tool #{tool_name}: #{e.message}"
        end
      end

      # Disconnect from the MCP server
      def disconnect
        return unless connected?

        begin
          @transport.close if @transport.respond_to?(:close)
        rescue StandardError => e
          warn "Error closing MCP transport for '#{@name}': #{e.message}"
        ensure
          @connected = false

          @mutex.synchronize do
            @tools_cache = nil
          end
        end
      end

      # Invalidate the tools cache, forcing a refresh on next list_tools call
      def invalidate_tools_cache
        @mutex.synchronize do
          @tools_cache = nil
        end
      end











      private



      # Determine which transport to use based on options
      #
      # @param options [Hash] Initialization options
      # @return [StdioTransport, HttpTransport, SseTransport] Appropriate transport instance
      # @raise [ArgumentError] If neither STDIO nor HTTP/SSE options provided
      def determine_transport(options)
        if options[:command] || options[:args]
          StdioTransport.new(
            command: options[:command] || "npx",
            args: options[:args] || [],
            env: options[:env] || {}
          )
        elsif options[:url]
          # Build headers 
          headers = options[:headers] || {}

          # Determine transport type: explicit, use_sse flag, or auto-detect
          transport_type = options[:transport_type]
          if transport_type.nil?
            transport_type = options[:use_sse] ? "sse" : "http"
          end

          # Common security options
          common_options = {
            url: options[:url],
            headers: headers,
            verify_ssl: options.fetch(:verify_ssl, true),
            allowed_origins: options[:allowed_origins] || []
          }

          case transport_type.to_s.downcase
          when "sse"
            SseTransport.new(**common_options)
          when "http"
            HttpTransport.new(**common_options)
          else
            # Default to HTTP transport
            HttpTransport.new(**common_options)
          end
        else
          raise ArgumentError, "Must provide either command or url"
        end
      end

      # Normalize filter patterns into a consistent format
      #
      # @param filter [String, Array, Regexp, nil] Filter specification
      # @return [Array<String, Regexp>] Normalized filter array
      def normalize_filter(filter)
        return [] if filter.nil?

        filters = Array(filter)
        filters.map do |f|
          case f
          when String
            # Convert wildcard patterns to regex
            if f.include?("*")
              pattern = f.gsub("*", ".*")
              /^#{pattern}$/
            else
              f
            end
          when Regexp
            f
          else
            f.to_s
          end
        end
      end

      # Check if a tool name matches any of the given filters
      #
      # @param tool_name [String] Tool name to check
      # @param filters [Array<String, Regexp>] Filter patterns
      # @return [Boolean] True if tool name matches any filter, or if no filters provided
      def matches_any_filter?(tool_name, filters)
        return true if filters.empty?

        filters.any? do |filter|
          case filter
          when String
            tool_name == filter
          when Regexp
            tool_name =~ filter
          else
            tool_name == filter.to_s
          end
        end
      end

      # Apply include/exclude filtering to tools list
      #
      # @param tools_data [Array<Hash>] Raw tool data from server
      # @return [Array<Hash>] Filtered tool data
      def filter_tools(tools_data)
        tools_data.select do |tool_data|
          tool_name = tool_data["name"]
          next false unless tool_name

          # Include if matches include filter (or no include filter)
          included = @include_tools.empty? || matches_any_filter?(tool_name, @include_tools)

          # Exclude if matches exclude filter (only exclude if there are exclude filters)
          excluded = !@exclude_tools.empty? && matches_any_filter?(tool_name, @exclude_tools)

          included && !excluded
        end
      end

      # Extract tools array from MCP server response
      #
      # @param response [Hash] Raw response from server
      # @return [Array<Hash>] Array of tool definitions
      # @raise [ProtocolError] If response format is invalid
      def extract_tools_from_response(response)
        if response.nil?
          []
        elsif response.is_a?(Hash) && response["tools"]
          response["tools"]
        elsif response.is_a?(Array)
          response # Direct array of tools
        else
          warn "Invalid tools list response format: #{response.class} - #{response.inspect}"
          []
        end
      end

      # Create tool instances from filtered tool data
      #
      # @param tools_data [Array<Hash>] Filtered tool definitions
      # @return [Array<Agents::MCP::Tool>] Tool instances
      def create_tool_instances(tools_data)
        # Remove duplicates by name (last one wins)
        unique_tools = tools_data.reverse.uniq { |tool| tool["name"] }.reverse

        unique_tools.map do |tool_data|
          Tool.create_from_mcp_data(tool_data, client: self)
        rescue StandardError => e
          warn "Failed to create MCP tool '#{tool_data["name"]}': #{e.message}"
          nil
        end.compact
      end
    end
  end
end
