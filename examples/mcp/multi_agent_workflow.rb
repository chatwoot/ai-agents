#!/usr/bin/env ruby
# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))

require "agents"

# Multi-agent workflow example using MCP integration
# This demonstrates how multiple agents can collaborate using shared MCP tools
# to accomplish complex tasks like documentation processing

# Configure the agents system
Agents.configure do |config|
  config.openai_api_key = ENV["OPENAI_API_KEY"]
  config.default_model = "gpt-4o-mini"
  config.debug = true
end

unless Agents.configuration.configured?
  puts "Please set OPENAI_API_KEY environment variable"
  exit 1
end

# Create shared MCP client for filesystem operations
filesystem_client = Agents::MCP::Client.new(
  name: "filesystem",
  command: "npx",
  args: ["-y", "@modelcontextprotocol/server-filesystem", "."],
  include_tools: ["read_file", "write_file", "list_directory"]
)

begin
  # Create specialized documentation agents using instance-based pattern

  # Research Agent - specializes in gathering information
  research_agent = Agents::Agent.new(
    name: "Research Agent",
    instructions: <<~PROMPT,
      You are a research agent that specializes in gathering and organizing information.
      You can read files and explore directory structures to understand projects.
      
      When handed a task, focus on:
      1. Exploring the project structure
      2. Reading relevant files
      3. Gathering key information
      4. Summarizing findings for other agents
      
      If you need analysis or writing done, hand off to the appropriate specialist.
    PROMPT
    mcp_clients: [filesystem_client]
  )

  # Analysis Agent - specializes in code analysis
  analysis_agent = Agents::Agent.new(
    name: "Analysis Agent",
    instructions: <<~PROMPT,
      You are an analysis agent that specializes in analyzing code and documentation.
      You can read files to understand their content and structure.
      
      When handed a task, focus on:
      1. Analyzing code structure and patterns
      2. Identifying key features and components
      3. Understanding architecture and design
      4. Providing insights and recommendations
      
      If you need research or writing done, hand off to the appropriate specialist.
    PROMPT
    mcp_clients: [filesystem_client]
  )

  # Writer Agent - specializes in documentation creation
  writer_agent = Agents::Agent.new(
    name: "Writer Agent",
    instructions: <<~PROMPT,
      You are a technical writer that specializes in creating clear documentation.
      You can read existing files and write new documentation files.
      
      When handed a task, focus on:
      1. Creating well-structured documentation
      2. Writing clear explanations
      3. Organizing information logically
      4. Saving documentation to appropriate files
      
      Always write documentation that is helpful and easy to understand.
    PROMPT
    mcp_clients: [filesystem_client]
  )

  # Set up handoff relationships
  research_agent.register_handoffs(analysis_agent, writer_agent)
  analysis_agent.register_handoffs(writer_agent)
  writer_agent.register_handoffs(research_agent, analysis_agent)

  # Execute multi-agent workflow
  user_request = <<~REQUEST
    I need you to create comprehensive documentation for this Ruby Agents SDK project.
    
    Please work together to:
    1. Research the project structure and understand the codebase
    2. Analyze the key components and architecture
    3. Write clear documentation that explains how to use the SDK
    
    Start by exploring the project structure, then hand off between agents as needed
    to accomplish this documentation task.
  REQUEST

  puts "Multi-agent documentation workflow starting..."
  puts "User request: #{user_request}"
  
  # Start with research agent
  result = Agents::Runner.run(research_agent, user_request)
  
  puts "\nWorkflow completed!"
  puts "Final result: #{result.output}"

rescue => e
  puts "Error during multi-agent workflow: #{e.message}"
  puts "Make sure you have Node.js and the MCP filesystem server available."
  exit 1
ensure
  filesystem_client&.disconnect
end