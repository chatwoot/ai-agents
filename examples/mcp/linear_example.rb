#!/usr/bin/env ruby
# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))

require "agents"

# Example demonstrating Linear MCP integration using mcp-remote proxy
# This example shows how to:
# 1. Connect to Linear's MCP server using the official mcp-remote proxy
# 2. Use Linear tools through MCP integration
#
# Prerequisites:
# - Node.js and npm installed (for mcp-remote)
# - LINEAR_ACCESS_TOKEN environment variable (optional)
#
# Setup:
# 1. Get a personal access token from Linear Settings > API (https://linear.app/settings/api)
# 2. Set LINEAR_ACCESS_TOKEN environment variable (optional for basic testing)

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

puts "Linear MCP Integration Example"
puts "=" * 40

puts "\nSetting up MCP Connection:"

# Configure MCP client
mcp_config = {
  name: "linear",
  command: "npx",
  args: ["-y", "mcp-remote", "https://mcp.linear.app/sse"]
}

# Create agent with Linear MCP client
agent = Agents::Agent.new(
  name: "Linear Assistant",
  instructions: <<~INSTRUCTIONS,
    You are a helpful assistant that can interact with Linear (the project management tool).

    You have access to Linear MCP tools that allow you to:
    - List teams and projects
    - View issues and their details
    - Create and update issues (if authenticated)
    - Search across Linear workspace

    When using Linear tools:
    1. Always check what teams/projects are available first
    2. Be specific about which workspace/team you're working with#{"  "}
    3. Provide clear summaries of the information you retrieve
    4. If authentication fails, explain the issue clearly

    Be helpful and provide context about what you're doing.
  INSTRUCTIONS
  mcp_clients: [mcp_config]
)

puts "✓ Agent created with Linear MCP client"

# Test connection and tools
puts "\nTesting MCP Connection:"

begin
  # Give the MCP client a moment to initialize
  sleep(2)

  # Try to get available tools
  tools = agent.all_tools.select { |tool| tool.is_a?(Agents::MCP::Tool) }

  if tools.any?
    puts "✓ Successfully connected to Linear MCP"
    puts "✓ Available tools: #{tools.length}"
    tools.each_with_index do |tool, i|
      tool_name = tool.respond_to?(:mcp_tool_name) ? tool.mcp_tool_name : tool.class.name
      puts "   #{i + 1}. #{tool_name}"
    end
  else
    puts "❌ No MCP tools loaded"
    puts "   This might be due to:"
    puts "   - Network connectivity issues"
    puts "   - mcp-remote package not available"
    puts "   - Linear MCP server issues"
  end
rescue StandardError => e
  puts "❌ Connection test failed: #{e.message}"
  puts "   Make sure npx and mcp-remote are available"
end

puts "\nTesting Agent Functionality:"

# Test scenarios
test_scenarios = [
  "Can you list the available teams or workspaces?",
  "Show me one recent issue if possible"
]

test_scenarios.each_with_index do |scenario, i|
  puts "\n#{i + 1}. Testing: #{scenario}"
  puts "-" * 40

  begin
    result = Agents::Runner.run(agent, scenario)

    if result && result.output
      puts "Response: #{result.output}"
    else
      puts "No response generated"
    end
  rescue StandardError => e
    puts "Error: #{e.message}"
  end

  puts ""
ensure
  # Clean shutdown
  agent&.mcp_manager&.shutdown
end
