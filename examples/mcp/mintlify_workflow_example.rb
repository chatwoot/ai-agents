#!/usr/bin/env ruby
# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))

require "agents"

# This example demonstrates a sophisticated multi-agent workflow using Mintlify MCP
# with multiple specialized agents working together in a documentation pipeline

# Configure the Ruby Agents SDK
Agents.configure do |config|
  config.openai_api_key = ENV["OPENAI_API_KEY"]
  config.default_model = "gpt-4o-mini"
end

unless Agents.configuration.configured?
  puts "Please set OPENAI_API_KEY environment variable"
  exit 1
end

# Create shared MCP clients for documentation workflow
mintlify_client = Agents::MCP::Client.new(
  name: "mintlify", 
  command: "node",
  args: ["/Users/tanmaydeepsharma/.mcp/acme-d0cb791b/src/index.js"],
)

filesystem_client = Agents::MCP::Client.new(
  name: "filesystem",
  command: "npx",
  args: ["-y", "@modelcontextprotocol/server-filesystem", Dir.home]
)

begin
  # Create specialized documentation agents

  # Triage agent - routes documentation requests
  triage_agent = Agents::Agent.new(
    name: "Documentation Triage",
    instructions: <<~INSTRUCTIONS
      You are a documentation workflow coordinator. Analyze the user's request and determine:
      1. If they need to search existing documentation - route to search specialist
      2. If they need to create new documentation - route to generator specialist
      3. If they need to edit/improve documentation - route to editor specialist
      
      Make your routing decision and explain why.
    INSTRUCTIONS
  )

  # Search agent - finds relevant documentation using Mintlify
  search_agent = Agents::Agent.new(
    name: "Documentation Search Specialist",
    instructions: <<~INSTRUCTIONS,
      You are a documentation search expert. Use Mintlify tools to:
      1. Search through existing documentation
      2. Find the most relevant information for user queries
      3. Summarize findings clearly
      4. Recommend next steps (generate new docs, edit existing ones, etc.)
    INSTRUCTIONS
    mcp_clients: [mintlify_client]
  )

  # Generator agent - creates new documentation
  generator_agent = Agents::Agent.new(
    name: "Documentation Generator",
    instructions: <<~INSTRUCTIONS,
      You are a technical documentation specialist. Create high-quality documentation by:
      1. Understanding user requirements
      2. Researching relevant information using available tools
      3. Writing clear, well-structured content
      4. Saving documentation to appropriate files using filesystem tools
      
      Always explain what you're creating and where you're saving it.
    INSTRUCTIONS
    mcp_clients: [mintlify_client, filesystem_client]
  )

  # Editor agent - refines and improves documentation
  editor_agent = Agents::Agent.new(
    name: "Documentation Editor",
    instructions: <<~INSTRUCTIONS,
      You are a documentation editor and file manager. Your role is to:
      1. Review and improve existing documentation
      2. Organize and structure documentation projects
      3. Save refined content to files using filesystem tools
      4. Ensure documentation follows best practices
      
      Provide clear feedback about improvements made and files created.
    INSTRUCTIONS
    mcp_clients: [filesystem_client, mintlify_client]
  )

  # Set up agent handoff relationships
  triage_agent.register_handoffs(search_agent, generator_agent, editor_agent)
  search_agent.register_handoffs(generator_agent, editor_agent)
  generator_agent.register_handoffs(editor_agent, search_agent)
  editor_agent.register_handoffs(search_agent, generator_agent)

  # Test workflow scenarios
  workflow_scenarios = [
    "I need to understand how authentication works in our API. Can you find the documentation and create a simple guide?",
    "Find information about rate limiting and generate a troubleshooting guide for developers",
    "Find the latest private message in conversation id 25?"
  ]

  workflow_scenarios.each_with_index do |scenario, i|
    puts "\nScenario #{i + 1}: #{scenario}"
    puts "-" * 60
    
    begin
      # Start with triage agent to route the request
      result = Agents::Runner.run(triage_agent, scenario)
      puts "Result: #{result.output}"
      
    rescue StandardError => e
      puts "Error in workflow: #{e.message}"
    end
  end

ensure
  mintlify_client&.disconnect
  filesystem_client&.disconnect
end