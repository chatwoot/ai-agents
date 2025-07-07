# frozen_string_literal: true

require "set"
require "timeout"

module Agents
  module MCP
    # MCP Manager provides a high-level interface for managing MCP clients and tools,
    # similar to how Agents::Chat wraps RubyLLM functionality. This class handles
    # connection management, error recovery, tool discovery, and provides a unified
    # interface for agent-tool integration.
    #
    # This abstraction solves several edge cases:
    # 1. Connection failures and recovery
    # 2. Tool name collisions across multiple clients
    # 3. Dynamic tool loading and caching
    # 4. Thread-safe operations
    # 5. Graceful degradation when MCP servers are unavailable
    #
    # @example Basic usage
    #   manager = Agents::MCP::Manager.new
    #
    #   # Add clients
    #   manager.add_client(
    #     name: "filesystem",
    #     command: "npx",
    #     args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
    #   )
    #
    #   # Get tools for agent
    #   tools = manager.get_agent_tools
    #
    #   # Execute tool
    #   result = manager.execute_tool("read_file", { path: "/tmp/test.txt" })
    #
    # @example With filtering and error handling
    #   manager = Agents::MCP::Manager.new(
    #     connection_retry_attempts: 3,
    #     connection_timeout: 30,
    #     enable_fallback_mode: true
    #   )
    #
    #   manager.add_client(
    #     name: "filesystem",
    #     command: "npx",
    #     args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
    #     include_tools: ["read_file", "write_file"],
    #     exclude_tools: ["delete_*"]
    #   )
    class Manager
      # Tool execution result that provides consistent interface
      class ToolExecutionResult
        attr_reader :success, :result, :error, :client_name, :tool_name

        def initialize(success:, result: nil, error: nil, client_name: nil, tool_name: nil)
          @success = success
          @result = result
          @error = error
          @client_name = client_name
          @tool_name = tool_name
        end

        def success?
          @success
        end

        def failure?
          !@success
        end

        def to_s
          if success?
            @result.respond_to?(:to_s) ? @result.to_s : @result.inspect
          else
            "Error: #{@error}"
          end
        end
      end

      attr_reader :clients, :options

      DEFAULT_OPTIONS = {
        connection_retry_attempts: 2,
        connection_timeout: 15,
        tool_call_timeout: 30,
        enable_fallback_mode: true,
        cache_tools: true,
        handle_collisions: :prefix, # :prefix, :error, :ignore
        collision_separator: "__"
      }.freeze

      # Initialize MCP Manager
      #
      # @param options [Hash] Configuration options
      # @option options [Integer] :connection_retry_attempts Number of connection retries
      # @option options [Integer] :connection_timeout Connection timeout in seconds
      # @option options [Integer] :tool_call_timeout Tool execution timeout in seconds
      # @option options [Boolean] :enable_fallback_mode Continue on client failures
      # @option options [Boolean] :cache_tools Cache discovered tools
      # @option options [Symbol] :handle_collisions How to handle tool name collisions
      # @option options [String] :collision_separator Separator for collision prefixes
      def initialize(options = {})
        @options = DEFAULT_OPTIONS.merge(options)
        @clients = {}
        @tools_cache = {}
        @client_health = {}
        @mutex = Mutex.new
      end

      # Add an MCP client to the manager
      #
      # @param name [String] Unique identifier for the client
      # @param options [Hash] Client configuration options
      # @return [Client] The created client
      # @raise [ArgumentError] If client name already exists
      def add_client(name:, **options)
        @mutex.synchronize do
          raise ArgumentError, "MCP client '#{name}' already exists" if @clients.key?(name)

          client = Client.new(name: name, **options)
          @clients[name] = client
          @client_health[name] = { healthy: false, last_check: nil, error: nil }

          # Clear cache when adding new clients
          @tools_cache.clear if @options[:cache_tools]

          client
        end
      end

      # Remove an MCP client from the manager
      #
      # @param name [String] Name of the client to release
      def remove_client(name)
        @mutex.synchronize do
          client = @clients.delete(name)
          @client_health.delete(name)
          @tools_cache.clear if @options[:cache_tools]

          if client
            begin
              client.disconnect
            rescue StandardError => e
              warn "Error disconnecting MCP client '#{name}': #{e.message}"
            end
          end
        end
      end

      # Get all available tools from all healthy clients
      #
      # @param refresh [Boolean] Force refresh of tools cache
      # @return [Array<Agents::Tool>] Array of available tools
      def get_agent_tools(refresh: false)
        @mutex.synchronize do
          # Return cached tools unless refresh requested
          return @tools_cache.values.flatten if @options[:cache_tools] && !@tools_cache.empty? && !refresh

          all_tools = []
          tool_names_seen = Set.new

          @clients.each do |client_name, client|
            # Check client health before attempting to get tools
            unless client_healthy?(client_name)
              next if @options[:enable_fallback_mode]

              raise ConnectionError, "MCP client '#{client_name}' is unhealthy"
            end

            # Get tools from client with timeout
            client_tools = timeout_operation(@options[:connection_timeout]) do
              client.list_tools(refresh: refresh)
            end

            # Handle tool name collisions
            resolved_tools = resolve_tool_name_collisions(
              client_tools,
              client_name,
              tool_names_seen
            )

            all_tools.concat(resolved_tools)

            # Update tool names seen
            resolved_tools.each do |tool|
              tool_names_seen.add(tool.class.name)
            end

            # Cache tools per client
            @tools_cache[client_name] = resolved_tools if @options[:cache_tools]
          rescue StandardError => e
            handle_client_error(client_name, e)
            next if @options[:enable_fallback_mode]

            raise
          end

          all_tools
        end
      end

      # Execute a tool by name
      #
      # @param tool_name [String] Name of the tool to execute
      # @param arguments [Hash] Arguments to pass to the tool
      # @param client_name [String, nil] Specific client to use (optional)
      # @return [ToolExecutionResult] Execution result
      def execute_tool(tool_name, arguments = {}, client_name: nil)
        # Find the client that owns this tool
        target_client = find_tool_owner(tool_name, client_name)

        unless target_client
          return ToolExecutionResult.new(
            success: false,
            error: "Tool '#{tool_name}' not found",
            tool_name: tool_name
          )
        end

        # Extract original tool name (handle collision prefixes)
        original_tool_name = extract_original_tool_name(tool_name, target_client[:name])

        begin
          # Execute with timeout
          result = timeout_operation(@options[:tool_call_timeout]) do
            target_client[:client].call_tool(original_tool_name, arguments)
          end

          ToolExecutionResult.new(
            success: true,
            result: result,
            client_name: target_client[:name],
            tool_name: tool_name
          )
        rescue StandardError => e
          handle_client_error(target_client[:name], e)

          ToolExecutionResult.new(
            success: false,
            error: e.message,
            client_name: target_client[:name],
            tool_name: tool_name
          )
        end
      end

      # Check if a client is healthy and connected
      #
      # @param client_name [String] Name of the client to check
      # @return [Boolean] True if client is healthy
      def client_healthy?(client_name)
        client = @clients[client_name]
        return false unless client

        health_info = @client_health[client_name] ||= { healthy: false, last_check: nil, status: "unknown" }

        # Check if we need to test connection
        if health_info[:last_check].nil? ||
           Time.now - health_info[:last_check] > 30 # 30 second health check cache

          begin
            # Ensure client is connected before testing health
            client.connect unless client.connected?

            # Test if connection is working by checking connected status
            is_healthy = client.connected?

            @client_health[client_name] = {
              healthy: is_healthy,
              last_check: Time.now,
              error: nil,
              status: is_healthy ? "connected" : "disconnected"
            }
            is_healthy
          rescue StandardError => e
            @client_health[client_name] = {
              healthy: false,
              last_check: Time.now,
              error: e.message,
              status: "error"
            }
            false
          end
        else
          health_info[:healthy]
        end
      end

      # Get health status of all clients
      #
      # @return [Hash] Health status by client name
      def client_health_status
        @mutex.synchronize do
          @client_health.transform_values do |health|
            {
              healthy: health[:healthy],
              last_check: health[:last_check],
              error: health[:error],
              status: health[:healthy] ? "connected" : "disconnected"
            }
          end
        end
      end

      # Refresh all client connections and tool caches
      #
      # @return [Hash] Results of refresh operation per client
      def refresh_all_clients
        results = {}

        @clients.each do |client_name, client|
          client.disconnect if client.connected?
          client.connect
          client.invalidate_tools_cache
          results[client_name] = { success: true, error: nil }
        rescue StandardError => e
          handle_client_error(client_name, e)
          results[client_name] = { success: false, error: e.message }
        end

        # Clear manager cache
        @mutex.synchronize { @tools_cache.clear }

        results
      end

      # Clean shutdown of all clients
      def shutdown
        @clients.each do |client_name, client|
          client.disconnect
        rescue StandardError => e
          warn "Error during shutdown of MCP client '#{client_name}': #{e.message}"
        end

        @mutex.synchronize do
          @clients.clear
          @tools_cache.clear
          @client_health.clear
        end
      end

      private

      # Execute operation with timeout
      def timeout_operation(timeout_seconds, &block)
        if defined?(Timeout)
          Timeout.timeout(timeout_seconds, &block)
        else
          yield # Fallback if Timeout not available
        end
      end

      # Handle client errors consistently
      def handle_client_error(client_name, error)
        @client_health[client_name] = {
          healthy: false,
          last_check: Time.now,
          error: error.message
        }

        warn "MCP client '#{client_name}' error: #{error.message}"

        # Remove from tools cache
        @tools_cache.delete(client_name) if @options[:cache_tools]
      end

      # Resolve tool name collisions based on configuration
      def resolve_tool_name_collisions(tools, client_name, existing_names)
        case @options[:handle_collisions]
        when :ignore
          # Just return tools as-is, duplicates will overwrite
          tools
        when :error
          # Raise error on collision
          collisions = tools.select { |tool| existing_names.include?(tool.class.name) }
          if collisions.any?
            collision_names = collisions.map { |t| t.class.name }.join(", ")
            raise ProtocolError, "Tool name collision detected: #{collision_names}"
          end
          tools
        when :prefix
          # Prefix colliding tools with client name
          tools.map do |tool|
            original_name = tool.class.name
            if existing_names.include?(original_name)
              # Create new tool class with prefixed name
              prefixed_name = "#{client_name}#{@options[:collision_separator]}#{original_name}"
              create_prefixed_tool(tool, prefixed_name, client_name)
            else
              tool
            end
          end
        else
          tools
        end
      end

      # Create a new tool instance with a prefixed name
      def create_prefixed_tool(original_tool, new_name, client_name)
        # Create new tool class that delegates to original
        tool_class = Class.new(Agents::Tool) do
          # Copy all the parameters from original tool
          original_tool.class.parameters.each do |param|
            param param.name, param.type, param.description, required: param.required
          end

          # Set new name and description
          define_singleton_method :name do
            new_name
          end

          # Delegate perform to original tool
          define_method :perform do |tool_context, **args|
            original_tool.perform(tool_context, **args)
          end

          # Store metadata about collision
          define_method :original_tool_name do
            original_tool.class.name
          end

          define_method :client_name do
            client_name
          end
        end

        tool_class.new
      end

      # Find which client owns a given tool
      def find_tool_owner(tool_name, preferred_client = nil)
        # Check preferred client first
        if preferred_client && @clients[preferred_client]
          return { name: preferred_client, client: @clients[preferred_client] }
        end

        # Get all available tools and find the one we need
        all_tools = get_agent_tools
        matching_tool = all_tools.find { |tool| tool.class.name == tool_name }

        return nil unless matching_tool

        # Find which client has this tool by checking the cache
        @clients.each do |client_name, client|
          next unless client_healthy?(client_name)

          tools = @tools_cache[client_name] || []
          return { name: client_name, client: client } if tools.any? { |tool| tool.equal?(matching_tool) }
        end

        nil
      end

      # Extract original tool name from potentially prefixed name
      def extract_original_tool_name(tool_name, client_name)
        prefix = "#{client_name}#{@options[:collision_separator]}"
        if tool_name.start_with?(prefix)
          tool_name[prefix.length..-1]
        else
          tool_name
        end
      end
    end
  end
end
