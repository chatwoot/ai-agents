# frozen_string_literal: true

require_relative 'dynamic_tool'

module Agents
  module MCP
    # Registry for dynamically discovered MCP tools
    class ToolRegistry
      @tools = {}
      @clients = {}

      class << self
        attr_reader :tools, :clients

        # Register an MCP client and discover its tools
        def register_client(name, client)
          @clients[name] = client
          discover_tools(name, client)
        end

        # Get all available tools
        def available_tools
          @tools.values.flatten
        end

        # Get tools for a specific MCP client
        def tools_for_client(client_name)
          @tools[client_name] || []
        end

        # Get a specific tool by name
        def get_tool(tool_name)
          @tools.values.flatten.find { |tool| tool.mcp_tool_name == tool_name }
        end

        # Clear all registered tools and clients
        def clear
          @tools = {}
          @clients = {}
        end

        # Refresh tools for all clients
        def refresh_all
          @clients.each do |name, client|
            discover_tools(name, client)
          end
        end

        # Get summary of discovered tools
        def summary
          summary_data = {
            total_clients: @clients.size,
            total_tools: @tools.values.flatten.size,
            clients: {}
          }

          @tools.each do |client_name, tools|
            summary_data[:clients][client_name] = {
              tool_count: tools.size,
              tools: tools.map { |tool| 
                {
                  name: tool.mcp_tool_name,
                  description: tool.tool_schema["description"]
                }
              }
            }
          end

          summary_data
        end

        private

        def discover_tools(client_name, client)
          begin
            puts "🔍 Discovering tools from #{client_name} MCP server..." if ENV['DEBUG']
            
            tool_schemas = client.list_tools
            dynamic_tools = []

            tool_schemas.each do |tool_schema|
              dynamic_tool = DynamicTool.new(tool_schema, client_name)
              dynamic_tools << dynamic_tool
              
              puts "  ✅ Discovered tool: #{tool_schema['name']}" if ENV['DEBUG']
            end

            @tools[client_name] = dynamic_tools
            puts "📋 Registered #{dynamic_tools.size} tools from #{client_name}" if ENV['DEBUG']

          rescue => e
            puts "❌ Failed to discover tools from #{client_name}: #{e.message}" if ENV['DEBUG']
            @tools[client_name] = []
          end
        end
      end
    end
  end
end