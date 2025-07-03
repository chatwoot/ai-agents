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
  config.debug = ENV["AGENTS_DEBUG"] == "true"
end

unless Agents.configuration.configured?
  puts "Please set OPENAI_API_KEY environment variable"
  exit 1
end

# Set the filesystem root directory - use current directory if not specified
filesystem_root = ENV["FILESYSTEM_ROOT"] || Dir.pwd
puts "Using filesystem root: #{filesystem_root}"

begin
  # Create an agent with MCP filesystem capabilities
  agent = Agents::Agent.new(
    name: "FileManager",
    instructions: "You are a helpful file management assistant. You can read, write, and list files in the allowed directory. Always be helpful and explain what you're doing.",
    mcp_clients: [{
      name: "filesystem",
      command: "npx",
      args: ["-y", "@modelcontextprotocol/server-filesystem", filesystem_root],
      include_tools: %w[read_file write_file list_files]
    }]
  )

  # Test the integration by trying to get tools first
  puts "Attempting to connect to filesystem MCP server..."
  tools = agent.mcp_manager.get_agent_tools(refresh: true)
  puts "Available tools: #{tools.map(&:name).join(", ")}"

  # Check client health after connection attempt
  health = agent.mcp_client_health
  puts "MCP Health after connection: #{health}"

  if health["filesystem"] && !health["filesystem"][:healthy]
    puts "Filesystem MCP client is not healthy. Error: #{health["filesystem"][:error]}"
    puts "Status: #{health["filesystem"][:status]}"
    puts "Please ensure the @modelcontextprotocol/server-filesystem package is available:"
    puts "  npm install -g @modelcontextprotocol/server-filesystem"
    exit 1
  end

  # Test scenarios
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
    puts "MCP Health: #{agent.mcp_client_health}"
    puts "--------------------------------------------------"
  end
rescue StandardError => e
  puts "Error during MCP integration test: #{e.message}"
  puts "Backtrace: #{e.backtrace.first(5).join("\n")}" if ENV["AGENTS_DEBUG"] == "true"
end
