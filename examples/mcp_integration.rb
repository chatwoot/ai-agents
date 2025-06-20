#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../lib/agents"
require 'json'
require 'net/http'
require 'uri'

# Configure the SDK
Agents.configure do |config|
  config.openai_api_key = ENV['OPENAI_API_KEY']
  config.default_provider = :openai
  config.default_model = "gpt-4o-mini"
end

# MCP (Model Context Protocol) Client Implementation
class MCPClient
  def initialize(server_url)
    @server_url = server_url
    @uri = URI.parse(server_url)
  end

  def call_tool(name, parameters = {})
    request_body = {
      method: "tools/call",
      params: {
        name: name,
        arguments: parameters
      }
    }

    begin
      response = make_request(request_body)
      response.dig("result", "content") || response.to_s
    rescue => e
      "MCP Error: #{e.message}"
    end
  end

  def list_tools
    request_body = { method: "tools/list" }
    
    begin
      response = make_request(request_body)
      response.dig("result", "tools") || []
    rescue => e
      puts "Error listing MCP tools: #{e.message}"
      []
    end
  end

  private

  def make_request(body)
    http = Net::HTTP.new(@uri.host, @uri.port)
    http.use_ssl = @uri.scheme == 'https'
    
    request = Net::HTTP::Post.new(@uri.path)
    request['Content-Type'] = 'application/json'
    request.body = body.to_json
    
    response = http.request(request)
    JSON.parse(response.body)
  end
end

# MCP-enabled tools that delegate to MCP servers
class FileSystemTool < Agents::ToolBase
  name "read_file"
  description "Read the contents of a file using MCP filesystem server"
  param :path, "string", "Path to the file to read", required: true

  def perform(path:, context: nil)
    mcp_client = context&.dig(:mcp_client)
    if mcp_client
      mcp_client.call_tool("read_file", { path: path })
    else
      # Fallback for demo purposes
      if File.exist?(path)
        File.read(path)
      else
        "File not found: #{path}"
      end
    end
  end
end

class DatabaseTool < Agents::ToolBase
  name "query_database"
  description "Execute SQL queries using MCP database server"
  param :query, "string", "SQL query to execute", required: true
  param :database, "string", "Database name", required: false

  def perform(query:, database: "main", context: nil)
    mcp_client = context&.dig(:mcp_client)
    if mcp_client
      mcp_client.call_tool("execute_query", { 
        query: query, 
        database: database 
      })
    else
      # Fallback simulation for demo
      "Query executed: #{query} on database '#{database}'"
    end
  end
end

class WebSearchTool < Agents::ToolBase
  name "web_search"
  description "Search the web using MCP web server"
  param :query, "string", "Search query", required: true
  param :limit, "integer", "Number of results", required: false

  def perform(query:, limit: 5, context: nil)
    mcp_client = context&.dig(:mcp_client)
    if mcp_client
      mcp_client.call_tool("search", { 
        query: query, 
        limit: limit 
      })
    else
      # Fallback simulation for demo
      "Web search results for '#{query}' (top #{limit} results simulated)"
    end
  end
end

# MCP-enhanced agents
class MCPCoordinator < Agents::Agent
  name "MCP Coordinator"
  instructions <<~PROMPT
    You are an MCP coordinator that routes requests to appropriate specialists:
    - For file operations, data analysis, or SQL queries: transfer to DataAnalysisAgent
    - For web research or finding online information: transfer to ResearchAgent
    
    You coordinate Model Context Protocol operations across different MCP servers.
  PROMPT
end

class DataAnalysisAgent < Agents::Agent
  name "Data Analysis Expert"
  instructions <<~PROMPT
    You are a data analysis expert with access to filesystem and database tools via MCP.
    You can read files, execute SQL queries, and analyze data. Always be thorough in your analysis.
  PROMPT

  uses FileSystemTool, DatabaseTool
end

class ResearchAgent < Agents::Agent
  name "Research Specialist"
  instructions <<~PROMPT
    You are a research specialist with web search capabilities via MCP.
    Help users find information online and provide comprehensive research.
  PROMPT

  uses WebSearchTool, FileSystemTool
end

# Set up handoffs after all classes are defined
MCPCoordinator.class_eval { handoffs DataAnalysisAgent, ResearchAgent }
DataAnalysisAgent.class_eval { handoffs ResearchAgent }
ResearchAgent.class_eval { handoffs DataAnalysisAgent }

# Enhanced context that includes MCP client
class MCPContext < Agents::Context
  attr_accessor :mcp_client, :connected_servers

  def initialize(data = {})
    super(data)
    @connected_servers = []
    setup_mcp_client if ENV['MCP_SERVER_URL']
  end

  private

  def setup_mcp_client
    @mcp_client = MCPClient.new(ENV['MCP_SERVER_URL'])
    @connected_servers << ENV['MCP_SERVER_URL']
    self[:mcp_client] = @mcp_client
  end
end

# Demo scenarios showcasing MCP integration
def run_mcp_demo
  puts "🔌 Ruby Agents SDK - MCP Integration Demo"
  puts "=" * 50
  
  # Create MCP-enabled context
  context = MCPContext.new
  runner = Agents::Runner.new(initial_agent: MCPCoordinator, context: context)
  
  scenarios = [
    {
      title: "File System Operations",
      message: "Can you read the README.md file and summarize its contents?",
      description: "Demonstrates MCP filesystem server integration"
    },
    {
      title: "Database Analysis", 
      message: "Execute a query to show all tables in the database and their record counts",
      description: "Shows MCP database server capabilities"
    },
    {
      title: "Web Research",
      message: "Search for the latest Ruby framework trends and best practices",
      description: "Illustrates MCP web search integration"
    },
    {
      title: "Multi-Tool Workflow",
      message: "Read the project configuration, analyze the database schema, and search for related documentation online",
      description: "Complex workflow using multiple MCP servers"
    }
  ]
  
  scenarios.each_with_index do |scenario, i|
    puts "\n" + "=" * 60
    puts "📋 Demo #{i+1}: #{scenario[:title]}"
    puts "📝 #{scenario[:description]}"
    puts "=" * 60
    puts "User: #{scenario[:message]}"
    puts "-" * 60
    
    if ENV['OPENAI_API_KEY']
      begin
        response = runner.process(scenario[:message])
        puts "🤖 Response: #{response}"
        
        # Show MCP server interactions
        if context.connected_servers.any?
          puts "\n🔌 MCP Servers Used: #{context.connected_servers.join(', ')}"
        end
        
        # Show agent transitions
        if context.agent_transitions.any?
          puts "\n🔄 Agent Flow:"
          context.agent_transitions.each do |transition|
            puts "  #{transition[:from]} → #{transition[:to]}: #{transition[:reason]}"
          end
        end
        
      rescue => e
        puts "❌ Error: #{e.message}"
      end
    else
      puts "🔧 Simulated Response: [MCP tools would be called here with real API]"
    end
    
    # Reset for next scenario
    context.clear_transitions
    puts "=" * 60
  end
end

# MCP Server Setup Instructions
def show_mcp_setup
  puts <<~SETUP
    🔧 MCP Server Setup Instructions:
    ==================================
    
    To use this example with real MCP servers:
    
    1. Install MCP servers:
       npm install -g @modelcontextprotocol/server-filesystem
       npm install -g @modelcontextprotocol/server-sqlite
    
    2. Start MCP servers:
       # Filesystem server
       npx @modelcontextprotocol/server-filesystem ./docs
       
       # Database server
       npx @modelcontextprotocol/server-sqlite ./data.db
    
    3. Set environment variables:
       export MCP_SERVER_URL=http://localhost:3000
       export OPENAI_API_KEY=your-api-key-here
    
    4. Run this example:
       ruby examples/mcp_integration.rb
    
    💡 This demo works without MCP servers by simulating responses.
  SETUP
end

# Main execution
if ARGV.include?('--setup')
  show_mcp_setup
else
  run_mcp_demo
  
  unless ENV['OPENAI_API_KEY']
    puts "\n💡 To see real AI responses, set OPENAI_API_KEY environment variable"
  end
  
  unless ENV['MCP_SERVER_URL']
    puts "\n💡 To use real MCP servers, set MCP_SERVER_URL and run --setup for instructions"
  end
  
  puts "\n✅ MCP Integration demo completed!"
end