#!/usr/bin/env ruby
# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))

require "agents"

# Example demonstrating MCP tool filtering capabilities
# This shows how to use include/exclude filters to control which tools
# are available to different agents for security and specialization

# Configure the agents system
Agents.configure do |config|
  config.openai_api_key = ENV["OPENAI_API_KEY"]
  config.default_model = "gpt-4o-mini"
end

unless Agents.configuration.configured?
  puts "Please set OPENAI_API_KEY environment variable"
  exit 1
end

# Create MCP clients with different filtering strategies

# Full access client (for admin agent)
full_access_client = Agents::MCP::Client.new(
  name: "filesystem_full",
  command: "npx",
  args: ["-y", "@modelcontextprotocol/server-filesystem", "."]
  # No filters - all tools available
)

# Read-only client (for security agent)
readonly_client = Agents::MCP::Client.new(
  name: "filesystem_readonly",
  command: "npx", 
  args: ["-y", "@modelcontextprotocol/server-filesystem", "."],
  include_tools: ["read_file", "list_directory"] # Only safe read operations
)

# Safe operations client (excludes dangerous operations)
safe_client = Agents::MCP::Client.new(
  name: "filesystem_safe",
  command: "npx",
  args: ["-y", "@modelcontextprotocol/server-filesystem", "."],
  exclude_tools: ["delete_file", "move_file"] # Exclude potentially destructive operations
)

# Pattern-based client (using wildcards and regex)
pattern_client = Agents::MCP::Client.new(
  name: "filesystem_pattern",
  command: "npx",
  args: ["-y", "@modelcontextprotocol/server-filesystem", "."],
  include_tools: [
    "file_*",        # Wildcard: matches file_read, file_write, etc.
    /^read_/,        # Regex: matches anything starting with "read_"
    "list_directory" # Exact match
  ]
)

# Create agents with different access levels

# Admin agent - full access
admin_agent = Agents::Agent.new(
  name: "Admin Agent",
  instructions: <<~INSTRUCTIONS,
    You are an admin agent with full filesystem access.
    You can perform any file operation including destructive ones.
    Always be careful with destructive operations and confirm before proceeding.
  INSTRUCTIONS
  mcp_clients: [full_access_client]
)

# Security agent - read-only access
security_agent = Agents::Agent.new(
  name: "Security Agent",
  instructions: <<~INSTRUCTIONS,
    You are a security agent with read-only filesystem access.
    You can examine files and directories but cannot make any changes.
    Focus on analyzing and reporting on file security and structure.
  INSTRUCTIONS
  mcp_clients: [readonly_client]
)

# Developer agent - safe operations only
developer_agent = Agents::Agent.new(
  name: "Developer Agent",
  instructions: <<~INSTRUCTIONS,
    You are a developer agent with safe filesystem operations.
    You can read, write, and create files but cannot delete or move them.
    Help with development tasks while maintaining file safety.
  INSTRUCTIONS
  mcp_clients: [safe_client]
)

# Pattern agent - pattern-based filtering
pattern_agent = Agents::Agent.new(
  name: "Pattern Agent",
  instructions: <<~INSTRUCTIONS,
    You are a specialized agent with pattern-filtered tool access.
    You have access to specific file operations based on naming patterns.
    Work within your available tool constraints.
  INSTRUCTIONS
  mcp_clients: [pattern_client]
)

begin
  # Display tool availability for each agent
  agents = [admin_agent, security_agent, developer_agent, pattern_agent]
  
  puts "Tool availability by agent:"
  agents.each do |agent|
    puts "\n#{agent.name}:"
    begin
      tools = agent.all_tools.select { |tool| tool.respond_to?(:class) && tool.class.name.start_with?("MCP") }
      if tools.any?
        tools.each { |tool| puts "  - #{tool.class.name}" }
      else
        puts "  - No MCP tools available"
      end
    rescue => e
      puts "  - Error loading tools: #{e.message}"
    end
  end

  # Test different agents with the same task
  test_task = "Please list the files in the current directory and read the README.md file if it exists"

  puts "\nTesting agents with identical requests:"
  agents.each do |agent|
    puts "\n#{agent.name}:"
    begin
      result = Agents::Runner.run(agent, test_task)
      output = result.output || "No output"
      truncated = output.length > 150 ? output[0..150] + "..." : output
      puts "Response: #{truncated}"
    rescue => e
      puts "Error: #{e.message}"
    end
    puts "-" * 40
  end

  # Demonstrate security through filtering
  destructive_task = "Delete the file 'mcp_test.txt' if it exists"
  
  puts "\nSecurity demonstration - destructive operation:"
  [admin_agent, security_agent].each do |agent|
    puts "\n#{agent.name}:"
    begin
      result = Agents::Runner.run(agent, destructive_task)
      puts "Response: #{result.output || 'No output'}"
    rescue => e
      puts "Error: #{e.message}"
    end
  end

rescue => e
  puts "Error during tool filtering demonstration: #{e.message}"
  exit 1
ensure
  # Clean up all clients
  [full_access_client, readonly_client, safe_client, pattern_client].each do |client|
    client&.disconnect
  end
end