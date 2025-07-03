#!/usr/bin/env ruby
# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))

require "agents"

# Multi-agent workflow example using Mintlify MCP integration
# This demonstrates a sophisticated documentation and conversation management workflow
# where specialized agents collaborate to handle different types of requests

# Configure the agents system with Mintlify API integration
Agents.configure do |config|
  config.openai_api_key = ENV["OPENAI_API_KEY"]
  config.default_model = "gpt-4o-mini"
  config.debug = ENV["AGENTS_DEBUG"] == "true"
end

unless Agents.configuration.configured?
  puts "Please set OPENAI_API_KEY environment variable"
  exit 1
end

# Configuration - customize these paths for your setup
#
# ACME SERVER SETUP:
# To add the acme server (Chatwoot documentation MCP server):
# 1. Install the server: Follow Chatwoot MCP server installation instructions (npx mint-mcp add acme-d0cb791b)
# 2. The server should be installed to: ~/.mcp/acme-d0cb791b/src/index.js
# 3. Update the path below to match your installation location
#
# MCP SERVER PATH CONFIGURATION:
# Option 1: Set environment variable (recommended)
#   export MINTLIFY_MCP_SERVER="/Users/yourusername/.mcp/acme-d0cb791b/src/index.js"
#
# Option 2: Update the default path below to match your system
#   Replace "/Users/username/.mcp/acme-d0cb791b/src/index.js" with your actual path
#
# Note: The acme-d0cb791b identifier may vary depending on your Chatwoot MCP installation
mintlify_server_path = ENV["MINTLIFY_MCP_SERVER"] || "/Users/tanmaydeepsharma/.mcp/acme-d0cb791b/src/index.js"

# FILESYSTEM ROOT CONFIGURATION:
# Set the root directory for filesystem operations
# Default: User's home directory
# Custom: Set FILESYSTEM_ROOT environment variable or update the path below
filesystem_root = ENV["FILESYSTEM_ROOT"] || Dir.home

# Define shared MCP client configurations
mintlify_config = {
  name: "mintlify",
  command: "node",
  args: [mintlify_server_path]
}

filesystem_config = {
  name: "filesystem",
  command: "npx",
  args: ["-y", "@modelcontextprotocol/server-filesystem", filesystem_root]
}

begin
  # Create specialized agents for documentation workflow

  # Triage Agent - routes requests to appropriate specialists
  triage_agent = Agents::Agent.new(
    name: "Request Triage",
    instructions: <<~INSTRUCTIONS
      You are a request coordinator. For every user request, immediately hand off to the appropriate specialist:

      • Documentation/conversation queries → handoff_to_data_documentation_specialist
      • File creation/writing tasks → handoff_to_documentation_generator
      • Find + create workflows → handoff_to_documentation_generator

      Always handoff immediately - never answer directly.
    INSTRUCTIONS
  )

  # Data Documentation Specialist - handles searches and data retrieval
  search_agent = Agents::Agent.new(
    name: "Data Documentation Specialist",
    instructions: <<~INSTRUCTIONS,
      You are a data retrieval expert with access to Chatwoot/Mintlify tools.

      For documentation searches: Use "search" tool with relevant keywords
      For conversation queries: Use "conversation-details" or "get-messages"
      For contact/account data: Use appropriate tools like "list-contacts"

      Provide requested information directly. Hand off to generator only if file creation is needed.
    INSTRUCTIONS
    mcp_clients: [mintlify_config]
  )

  # Documentation Generator - creates files and handles complex workflows
  generator_agent = Agents::Agent.new(
    name: "Documentation Generator",
    instructions: <<~INSTRUCTIONS,
      You are a technical documentation specialist. Complete the full workflow:

      1. First: Use "search" tool to find existing information
      2. Then: Use "write_file" to create requested documentation
      3. Always complete both steps when file creation is requested

      Available tools include search, write_file, read_file, and list_directory.
    INSTRUCTIONS
    mcp_clients: [mintlify_config, filesystem_config]
  )

  # Documentation Editor - refines and improves content
  editor_agent = Agents::Agent.new(
    name: "Documentation Editor",
    instructions: <<~INSTRUCTIONS,
      You are a documentation editor specializing in:
      • Reviewing and improving existing documentation
      • Organizing documentation projects
      • Ensuring content follows best practices

      Use filesystem tools to read, edit, and organize files effectively.
    INSTRUCTIONS
    mcp_clients: [filesystem_config, mintlify_config]
  )

  # Set up agent handoff relationships
  triage_agent.register_handoffs(search_agent, generator_agent, editor_agent)
  search_agent.register_handoffs(generator_agent, editor_agent)
  generator_agent.register_handoffs(editor_agent, search_agent)
  editor_agent.register_handoffs(search_agent, generator_agent)

  # Example workflow scenarios
  scenarios = [
    "Find authentication documentation and create a simple implementation guide",
    "Get the latest messages from conversation ID 25 in account 1",
    "Search for rate limiting information and generate a troubleshooting guide"
  ]

  puts "Mintlify Multi-Agent Workflow Example"
  puts "=" * 50

  scenarios.each_with_index do |scenario, i|
    puts "\nScenario #{i + 1}: #{scenario}"
    puts "-" * 40

    result = Agents::Runner.run(triage_agent, scenario)
    puts "Result: #{result.output}"

    puts "Error: #{result.error.message}" if result.error
  end
rescue StandardError => e
  puts "Error during workflow execution: #{e.message}"
  puts "Make sure MINTLIFY_MCP_SERVER path is correct and server is accessible"
  exit 1
ensure
  # Clean shutdown of all MCP connections
  [search_agent, generator_agent, editor_agent].each do |agent|
    agent&.mcp_manager&.shutdown
  end
end
