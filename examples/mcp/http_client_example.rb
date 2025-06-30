#!/usr/bin/env ruby
# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))

require "agents"

# Example demonstrating MCP integration with an HTTP server
# This example shows how to:
# 1. Create an MCP client for an HTTP server
# 2. Attach it to an agent
# 3. Use the agent to perform API operations

# Configure the agents system
Agents.configure do |config|
  config.openai_api_key = ENV["OPENAI_API_KEY"]
  config.default_model = "gpt-4o-mini"
  config.debug = false
end

unless Agents.configuration.configured?
  puts "Please set OPENAI_API_KEY environment variable"
  exit 1
end

# Create MCP client for HTTP server
http_client = Agents::MCP::Client.new(
  name: "api_server", 
  url: "http://localhost:4568",
  headers: {
    "Content-Type" => "application/json",
    "User-Agent" => "Ruby-Agents-MCP/1.0"
  }
)

# Test direct client connection
begin
  http_client.connect
  tools = http_client.list_tools
  puts "Connected! Found #{tools.length} tools: #{tools.map { |t| t.class.name }.join(', ')}"
rescue => e
  puts "Failed to connect to HTTP MCP server: #{e.message}"
  puts "Make sure the HTTP server is running: ruby examples/mcp/http_server_example.rb"
  exit 1
end

# Create agent with MCP client
agent = Agents::Agent.new(
  name: "API Assistant",
  instructions: <<~INSTRUCTIONS,
    You are a helpful API assistant that can interact with a user database.
    You have access to tools that can get users, get specific users by ID, and create new users.
    
    Always be helpful and explain what data you're retrieving or creating.
    When showing user data, format it nicely for the user.
  INSTRUCTIONS
  mcp_clients: [http_client]
)

begin
  # Test scenarios for HTTP MCP integration
  test_scenarios = [
    "Use the get_users tool to get all users from the database and show them in a nice format",
    "Use the get_user tool to get the user with ID 2 and tell me about them", 
    "Use the create_user tool to create a new user named 'Diana' with email 'diana@example.com'",
    "Use the get_user tool to try to get the user with ID 999"
  ]

  test_scenarios.each_with_index do |scenario, i|
    puts "Test #{i + 1}: #{scenario}"
    result = Agents::Runner.run(agent, scenario)
    puts "Response: #{result.output}"
    puts "-" * 50
  end

rescue => e
  puts "Error during HTTP MCP integration test: #{e.message}"
  puts "Make sure the HTTP MCP server is running: ruby examples/mcp/http_server_example.rb"
  exit 1
ensure
  http_client&.disconnect
end