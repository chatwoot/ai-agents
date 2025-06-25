#!/usr/bin/env ruby
# frozen_string_literal: true

# MCP Tool Filtering Example for Ruby Agents SDK
# This example demonstrates how to include or exclude specific tools from MCP servers

require_relative "../../lib/agents"

# Configure the agents system
Agents.configure do |config|
  config.openai_api_key = ENV["OPENAI_API_KEY"] || "your-api-key-here"
  config.default_model = "gpt-4o-mini"
  config.debug = true
end

# Example: Agent with filesystem tools but only read operations
class ReadOnlyFilesystemAgent < Agents::Agent
  name "Read-Only Filesystem Assistant"
  instructions "You can help users read and list files, but cannot write or modify files."
  
  # Create filesystem MCP client with only read-related tools
  filesystem_client = Agents::MCP::Client.new(
    name: "Filesystem",
    command: "npx",
    args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
  )
  
  # Register client with tool filtering - only include read operations
  mcp_client filesystem_client, 
             include_tools: ["read_file", "list_directory", "get_file_info"]
end

# Example: Agent with filesystem tools but excluding dangerous operations  
class SafeFilesystemAgent < Agents::Agent
  name "Safe Filesystem Assistant"
  instructions "You can help users with file operations, but cannot delete files or execute commands."
  
  # Create filesystem MCP client
  filesystem_client = Agents::MCP::Client.new(
    name: "Filesystem", 
    command: "npx",
    args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
  )
  
  # Register client excluding dangerous operations
  mcp_client filesystem_client,
             exclude_tools: ["delete_file", "execute_command", "remove_*"]
end

# Example: Agent with multiple MCP clients with different filters
class SelectiveToolsAgent < Agents::Agent
  name "Selective Tools Assistant"
  instructions "You have access to specific tools from multiple MCP servers."
  
  # Filesystem client - only listing and reading
  fs_client = Agents::MCP::Client.new(
    name: "Filesystem",
    command: "npx", 
    args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
  )
  
  # Register filesystem client with filtering
  mcp_client fs_client, include_tools: ["read_file", "list_directory"]
end

# Example: Using glob patterns for tool filtering
class GlobPatternAgent < Agents::Agent
  name "Glob Pattern Assistant"
  instructions "You use glob patterns to filter tools from MCP servers."
  
  # Create a client for demonstration
  demo_client = Agents::MCP::Client.new(
    name: "DemoServer",
    command: "demo-mcp-server",
    args: []
  )
  
  # Register client with glob patterns
  # Include all read_* tools and exclude all delete_* tools
  mcp_client demo_client,
             include_tools: ["read_*", "list_*"],
             exclude_tools: ["delete_*", "*_dangerous_*"]
end

# Example: Using regex patterns for advanced filtering
class RegexPatternAgent < Agents::Agent
  name "Regex Pattern Assistant"
  instructions "You use regex patterns for advanced tool filtering."
  
  # Create a client for demonstration
  demo_client = Agents::MCP::Client.new(
    name: "DemoServer",
    command: "demo-mcp-server",
    args: []
  )
  
  # Register client with regex patterns
  # Include tools that start with 'get_' or 'list_' but exclude any with 'admin'
  mcp_client demo_client,
             include_tools: [/^(get_|list_)/, "read_file"],
             exclude_tools: [/admin/, /danger/]
end

# Example usage function
def demonstrate_tool_filtering
  puts "=== MCP Tool Filtering Demonstration ==="
  puts
  
  # Example 1: Read-only filesystem agent
  puts "1. Read-Only Filesystem Agent:"
  readonly_agent = ReadOnlyFilesystemAgent.new
  puts "  Available tools: #{readonly_agent.metadata[:tools]}"
  puts "  (Should only include read operations)"
  puts
  
  # Example 2: Safe filesystem agent
  puts "2. Safe Filesystem Agent:"
  safe_agent = SafeFilesystemAgent.new
  puts "  Available tools: #{safe_agent.metadata[:tools]}"
  puts "  (Should exclude dangerous operations)"
  puts
  
  # Example 3: Selective tools agent
  puts "3. Selective Tools Agent:"
  selective_agent = SelectiveToolsAgent.new
  puts "  Available tools: #{selective_agent.metadata[:tools]}"
end

# Run the demonstration if this file is executed directly
if __FILE__ == $0
  demonstrate_tool_filtering
end