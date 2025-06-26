#!/usr/bin/env ruby
# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))

require "agents"

# Example demonstrating MCP integration with a filesystem server
# This example shows how to:
# 1. Create an MCP client for a filesystem server
# 2. Attach it to an agent
# 3. Use the agent to perform file operations

# Configure the agents system
Agents.configure do |config|
  config.openai_api_key = ENV["OPENAI_API_KEY"]
  config.default_model = "gpt-4o-mini"
  config.debug = false

  config.enable_tracing!

  # Optional: Configure tracing details
  config.tracing.export_path = "./examples/tracing/traces"
  config.tracing.include_sensitive_data = true  # For demo purposes
  config.tracing.console_output = true
  config.tracing.otel_format = true
  config.tracing.service_name = "basic_example"
end

unless Agents.configuration.configured?
  puts "Please set OPENAI_API_KEY environment variable"
  exit 1
end

# Create MCP client for filesystem server
# This uses the @modelcontextprotocol/server-filesystem package via npx
filesystem_client = Agents::MCP::Client.new(
  name: "filesystem",
  command: "npx",
  args: ["-y", "@modelcontextprotocol/server-filesystem", "."],
  include_tools: ["read_file", "write_file", "list_directory"], # Only allow safe operations
  exclude_tools: ["move_file"] # Exclude potentially dangerous operations
)

# Create agent with MCP client
agent = Agents::Agent.new(
  name: "File Assistant",
  instructions: <<~INSTRUCTIONS,
    You are a helpful file assistant that can read, write, and list files.
    You have access to filesystem tools through MCP integration.
    
    Always be helpful and explain what you're doing when working with files.
    If a file doesn't exist, offer to create it. Be mindful of file safety.
  INSTRUCTIONS
  mcp_clients: [filesystem_client]
)

begin
  # Test the integration with various file operations
  test_scenarios = [
    "Please list the files in the current directory",
    "Please read the contents of README.md file",
    "Create a file called 'mcp_test.txt' with the content 'Hello from MCP integration!'",
    "Read the contents of mcp_test.txt"
  ]

  test_scenarios.each_with_index do |scenario, i|
    puts "Test #{i + 1}: #{scenario}"
    result = Agents::Runner.run(agent, scenario)
    puts "Response: #{result.output}"
    puts "-" * 50
  end

rescue => e
  puts "Error during MCP integration test: #{e.message}"
  exit 1
ensure
  filesystem_client&.disconnect
end