$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))

require "agents"

# This example demonstrates HTTP MCP client connecting to our simple HTTP MCP server
# Prerequisites: 
# 1. Install sinatra: gem install sinatra
# 2. Start the HTTP MCP server: ruby examples/mcp/simple_http_mcp_server.rb
# 3. Run this client example

# Configure the Ruby Agents SDK
Agents.configure do |config|
  config.openai_api_key = ENV["OPENAI_API_KEY"]
  config.default_model = "gpt-4o-mini"
end

# Check if we're properly configured
unless Agents.configuration.configured?
  puts "No API keys configured. Please set OPENAI_API_KEY environment variable."
  puts "Example: export OPENAI_API_KEY=your_key_here"
  exit 1
end

# Create HTTP MCP client pointing to our local server
HTTP_MCP_CLIENT = Agents::MCP::Client.new(
  name: "LocalDatabase",
  url: "http://localhost:3001/mcp",
  headers: {
    "Content-Type" => "application/json"
  }
)

# Define an agent that uses the HTTP MCP server
class DatabaseAgent < Agents::Agent
  name "Database Assistant"
  instructions <<~PROMPT
    You are a database assistant with access to user and task management tools.
    
    You can help users:
    1. Get information about users in the system
    2. Look up specific users by ID
    3. Retrieve and filter tasks by user or status
    4. Create new tasks for users
    
    Use the available database tools to provide accurate and helpful information.
    When creating tasks, make sure to assign them to valid user IDs (1, 2, or 3).
  PROMPT

  mcp_clients HTTP_MCP_CLIENT
end

def test_http_connection
  puts "Testing HTTP MCP server connection..."
  
  begin
    # Check if server is running
    require 'net/http'
    uri = URI('http://localhost:3001/health')
    response = Net::HTTP.get_response(uri)
    
    if response.code == '200'
      puts "✅ HTTP MCP server is running"
    else
      puts "❌ HTTP MCP server returned status: #{response.code}"
      return false
    end
  rescue => e
    puts "❌ Cannot connect to HTTP MCP server: #{e.message}"
    puts "   Make sure to start the server first:"
    puts "   ruby examples/mcp/simple_http_mcp_server.rb"
    return false
  end
  
  true
end

begin
  # Test server connection first
  unless test_http_connection
    exit 1
  end
  
  puts "\nConnecting to HTTP MCP server..."
  HTTP_MCP_CLIENT.connect
  puts "✅ Connected to HTTP MCP server"
  
  puts "\nListing available tools..."
  tools = HTTP_MCP_CLIENT.list_tools
  puts "Found #{tools.count} tools:"
  tools.each do |tool|
    puts "  • #{tool.name}: #{tool.description}"
  end
  
  puts "\nTesting direct tool calls..."
  
  # Test 1: Get all users
  puts "\n1. Getting all users..."
  result = HTTP_MCP_CLIENT.call_tool("get_users", {})
  puts "Result: #{result}"
  
  # Test 2: Get specific user
  puts "\n2. Getting user by ID..."
  result = HTTP_MCP_CLIENT.call_tool("get_user_by_id", { user_id: 1 })
  puts "Result: #{result}"
  
  # Test 3: Get tasks filtered by status
  puts "\n3. Getting pending tasks..."
  result = HTTP_MCP_CLIENT.call_tool("get_tasks", { status: "pending" })
  puts "Result: #{result}"
  
  # Test 4: Create new task
  puts "\n4. Creating new task..."
  result = HTTP_MCP_CLIENT.call_tool("create_task", { 
    title: "Test HTTP MCP integration", 
    user_id: 1, 
    status: "pending" 
  })
  puts "Result: #{result}"
  
  puts "\nTesting agent with HTTP MCP tools..."
  agent = DatabaseAgent.new
  
  test_queries = [
    "Show me all users in the system",
    "What tasks are assigned to user 1?",
    "Create a new task called 'Review HTTP MCP implementation' and assign it to user 2"
  ]
  
  test_queries.each do |query|
    puts "\nUser: #{query}"
    
    begin
      response = agent.call(query)
      puts "Agent: #{response.content}"
    rescue StandardError => e
      puts "Error: #{e.message}"
    end
    puts "-" * 50
  end
ensure
  HTTP_MCP_CLIENT&.disconnect if HTTP_MCP_CLIENT&.connected?
end
