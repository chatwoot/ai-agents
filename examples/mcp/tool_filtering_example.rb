#!/usr/bin/env ruby
# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))

require "agents"

# Example demonstrating MCP tool filtering capabilities
# This shows how to use include/exclude filters to control which tools
# are available to different agents for security and specialization

puts "MCP Tool Filtering Example"
puts "=" * 50

# Check for dry run mode (just show tool loading without API calls)
dry_run = !ENV["OPENAI_API_KEY"] || ENV["DRY_RUN"] == "true"

if dry_run
  puts "\n🔍 DRY RUN MODE (no API key found or DRY_RUN=true)"
  puts "This will demonstrate tool filtering without making API calls."
else
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
end

# Set the filesystem root directory - use current directory if not specified
filesystem_root = ENV["FILESYSTEM_ROOT"] || Dir.pwd
puts "\nUsing filesystem root: #{filesystem_root}"

# Define MCP client configurations with different filtering strategies

# Full access configuration (for admin agent)
full_access_config = {
  name: "filesystem_full",
  command: "npx",
  args: ["-y", "@modelcontextprotocol/server-filesystem", filesystem_root]
  # No filters - all tools available
}

# Read-only configuration (for security agent)
readonly_config = {
  name: "filesystem_readonly",
  command: "npx",
  args: ["-y", "@modelcontextprotocol/server-filesystem", filesystem_root],
  include_tools: %w[read_file list_directory] # Only safe read operations
}

# Safe operations configuration (excludes dangerous operations)
safe_config = {
  name: "filesystem_safe",
  command: "npx",
  args: ["-y", "@modelcontextprotocol/server-filesystem", filesystem_root],
  exclude_tools: %w[delete_file move_file] # Exclude potentially destructive operations
}

# Pattern-based configuration (using wildcards and regex)
pattern_config = {
  name: "filesystem_pattern",
  command: "npx",
  args: ["-y", "@modelcontextprotocol/server-filesystem", filesystem_root],
  include_tools: [
    "file_*",        # Wildcard: matches file_read, file_write, etc.
    /^read_/,        # Regex: matches anything starting with "read_"
    "list_directory" # Exact match
  ]
}

puts "\nAgent Configurations:"
puts "-" * 30

configs = [
  { name: "Admin Agent", config: full_access_config, description: "Full access (no filters)" },
  { name: "Security Agent", config: readonly_config, description: "Read-only access" },
  { name: "Developer Agent", config: safe_config, description: "Safe operations (excludes dangerous)" },
  { name: "Pattern Agent", config: pattern_config, description: "Pattern-based filtering" }
]

configs.each do |agent_info|
  puts "\n#{agent_info[:name]}:"
  puts "  Description: #{agent_info[:description]}"
  
  config = agent_info[:config]
  if config[:include_tools]
    puts "  Include tools: #{config[:include_tools].inspect}"
  end
  if config[:exclude_tools]
    puts "  Exclude tools: #{config[:exclude_tools].inspect}"
  end
  puts "  Filter strategy: #{config[:include_tools] ? 'Whitelist' : config[:exclude_tools] ? 'Blacklist' : 'No filters'}"
end

begin
  # Create agents with different access levels using modern configuration approach

  # Admin agent - full access
  admin_agent = Agents::Agent.new(
    name: "Admin Agent",
    instructions: <<~INSTRUCTIONS,
      You are an admin agent with full filesystem access.
      You can perform any file operation including destructive ones.
      Always be careful with destructive operations and confirm before proceeding.
    INSTRUCTIONS
    mcp_clients: [full_access_config]
  )

  # Security agent - read-only access
  security_agent = Agents::Agent.new(
    name: "Security Agent",
    instructions: <<~INSTRUCTIONS,
      You are a security agent with read-only filesystem access.
      You can examine files and directories but cannot make any changes.
      Focus on analyzing and reporting on file security and structure.
    INSTRUCTIONS
    mcp_clients: [readonly_config]
  )

  # Developer agent - safe operations only
  developer_agent = Agents::Agent.new(
    name: "Developer Agent",
    instructions: <<~INSTRUCTIONS,
      You are a developer agent with safe filesystem operations.
      You can read, write, and create files but cannot delete or move them.
      Help with development tasks while maintaining file safety.
    INSTRUCTIONS
    mcp_clients: [safe_config]
  )

  # Pattern agent - pattern-based filtering
  pattern_agent = Agents::Agent.new(
    name: "Pattern Agent",
    instructions: <<~INSTRUCTIONS,
      You are a specialized agent with pattern-filtered tool access.
      You have access to specific file operations based on naming patterns.
      Work within your available tool constraints.
    INSTRUCTIONS
    mcp_clients: [pattern_config]
  )

  # Display tool availability for each agent
  agents = [admin_agent, security_agent, developer_agent, pattern_agent]

  puts "\n\nTool Loading Results:"
  puts "-" * 30
  
  agents.each do |agent|
    puts "\n#{agent.name}:"
    begin
      # Get all tools and identify MCP tools
      all_tools = agent.all_tools
      mcp_tools = all_tools.select { |tool| tool.is_a?(Agents::MCP::Tool) }
      
      if mcp_tools.any?
        mcp_tools.each do |tool|
          # Get the tool name from the MCP tool
          tool_name = tool.respond_to?(:mcp_tool_name) ? tool.mcp_tool_name : tool.class.name
          puts "  ✓ #{tool_name}"
        end
        puts "  Total: #{mcp_tools.length} MCP tools"
      else
        puts "  - No MCP tools available"
      end
    rescue StandardError => e
      puts "  ❌ Error loading tools: #{e.message}"
    end
  end

  if dry_run
    puts "\n\n🎯 Tool Filtering Analysis:"
    puts "-" * 30
    puts "\nThe example demonstrates how different filtering strategies work:"
    puts "• Admin Agent: Gets all available tools (no restrictions)"
    puts "• Security Agent: Only gets read_file and list_directory (whitelist)"
    puts "• Developer Agent: Gets all tools except delete_file and move_file (blacklist)"
    puts "• Pattern Agent: Gets tools matching patterns like 'file_*' and /^read_/"
    puts "\nThis allows you to create specialized agents with restricted capabilities"
    puts "for security, role-based access control, and focused functionality."
    puts "\n✅ Tool filtering demonstration completed successfully"
    return
  end

  # Test different agents with the same task (only if not dry run)
  test_task = "Please list the files in the current directory and read the README.md file if it exists"

  puts "\n\nTesting agents with identical requests:"
  puts "-" * 50
  
  agents.each do |agent|
    puts "\n#{agent.name}:"
    begin
      result = Agents::Runner.run(agent, test_task)
      if result.nil?
        puts "Response: No result returned"
      elsif result.respond_to?(:output)
        output = result.output || "No output"
        truncated = output.length > 200 ? output[0..200] + "..." : output
        puts "Response: #{truncated}"
      else
        puts "Response: #{result}"
      end
    rescue StandardError => e
      puts "Error: #{e.message}"
    end
    puts "-" * 40
  end

  # Demonstrate pattern filtering effectiveness
  pattern_task = "Try to use any available file operations to show what you can do"

  puts "\nPattern filtering demonstration:"
  puts "-" * 50
  
  puts "\n#{pattern_agent.name}:"
  begin
    result = Agents::Runner.run(pattern_agent, pattern_task)
    if result.nil?
      puts "Response: No result returned"
    elsif result.respond_to?(:output)
      output = result.output || "No output"
      truncated = output.length > 300 ? output[0..300] + "..." : output
      puts "Response: #{truncated}"
    else
      puts "Response: #{result}"
    end
  rescue StandardError => e
    puts "Error: #{e.message}"
  end

  puts "\n✅ Tool filtering demonstration completed successfully"

rescue StandardError => e
  puts "\n❌ Error during tool filtering demonstration: #{e.message}"
  puts "Please ensure the filesystem MCP server is available via npx"
  exit 1
ensure
  # Clean shutdown of all MCP connections
  if defined?(agents)
    agents&.each do |agent|
      begin
        agent&.mcp_manager&.shutdown
      rescue StandardError => e
        warn "Error shutting down MCP manager for #{agent.name}: #{e.message}"
      end
    end
  end
end


