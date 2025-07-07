---
layout: default
title: MCP Server Integration
parent: Guides
nav_order: 4
---

# MCP Server Integration

This guide covers integrating Model Context Protocol (MCP) servers with AI Agents to extend agent capabilities with external tools and services. MCP allows agents to dynamically discover and use tools from various servers, enabling powerful integrations with filesystems, APIs, databases, and custom services.

## What is MCP?

Model Context Protocol (MCP) is a standardized protocol for connecting AI models to external tools and data sources. It allows agents to:

- **Dynamically discover tools** from external servers
- **Execute remote operations** through standardized interfaces
- **Access external systems** like filesystems, databases, and APIs
- **Extend capabilities** without modifying core agent code

## Core Concepts

### MCP Clients

MCP clients connect to and communicate with MCP servers:

```ruby
# STDIO transport (subprocess)
filesystem_client = Agents::MCP::Client.new(
  name: "filesystem",
  command: "npx",
  args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
  include_tools: %w[read_file write_file list_files]
)

# HTTP transport
api_client = Agents::MCP::Client.new(
  name: "api_server",
  url: "http://localhost:8000",
  headers: { "Authorization" => "Bearer #{api_token}" }
)
```

### Tool Filtering

Control which tools agents can access using include/exclude patterns:

```ruby
# Include only specific tools
client = Agents::MCP::Client.new(
  name: "filesystem",
  command: "npx",
  args: ["-y", "@modelcontextprotocol/server-filesystem", "."],
  include_tools: %w[read_file write_file],  # Only allow file operations
  exclude_tools: %w[delete_file]           # Explicitly deny dangerous operations
)

# Use regex patterns for flexible matching
client = Agents::MCP::Client.new(
  name: "database",
  command: "db-mcp-server",
  include_tools: [/^read_/, /^query_/],    # Only read and query operations
  exclude_tools: [/^delete_/, /^drop_/]    # Block destructive operations
)
```

## Transport Types

### STDIO Transport

Connect to subprocess-based MCP servers:

```ruby
# Basic filesystem server
agent = Agents::Agent.new(
  name: "FileManager",
  instructions: "You can manage files in the current directory.",
  mcp_clients: [{
    name: "filesystem",
    command: "npx",
    args: ["-y", "@modelcontextprotocol/server-filesystem", "."],
    include_tools: %w[read_file write_file list_files]
  }]
)

# Custom environment variables
agent = Agents::Agent.new(
  name: "DatabaseAgent",
  instructions: "You can query and manage database records.",
  mcp_clients: [{
    name: "database", 
    command: "python",
    args: ["/path/to/db_server.py"],
    env: {
      "DB_CONNECTION_STRING" => "postgresql://localhost/mydb",
      "DB_POOL_SIZE" => "10"
    }
  }]
)
```

### HTTP Transport

Connect to HTTP-based MCP servers:

```ruby
# Basic HTTP connection
agent = Agents::Agent.new(
  name: "APIAgent",
  instructions: "You can interact with external APIs.",
  mcp_clients: [{
    name: "external_api",
    url: "https://api.example.com",
    headers: {
      "Authorization" => "Bearer #{ENV['API_TOKEN']}",
      "User-Agent" => "AI-Agents/1.0"
    },
    verify_ssl: true,
    allowed_origins: ["api.example.com"]
  }]
)

# Server-Sent Events (SSE) transport
agent = Agents::Agent.new(
  name: "RealtimeAgent",
  instructions: "You can access real-time data streams.",
  mcp_clients: [{
    name: "realtime_api",
    url: "https://stream.example.com",
    use_sse: true,
    headers: { "Accept" => "text/event-stream" }
  }]
)
```

## Agent Integration Patterns

### Single Agent with MCP Tools

Add MCP capabilities to individual agents:

```ruby
# Create agent with filesystem capabilities
file_agent = Agents::Agent.new(
  name: "FileManager",
  instructions: <<~INSTRUCTIONS,
    You are a file management assistant. You can:
    - Read and write files
    - List directory contents
    - Organize and manage files
    
    Always explain what you're doing and ask for confirmation before making changes.
  INSTRUCTIONS
  mcp_clients: [{
    name: "filesystem",
    command: "npx", 
    args: ["-y", "@modelcontextprotocol/server-filesystem", Dir.pwd],
    include_tools: %w[read_file write_file list_files]
  }]
)

# Test the integration
result = Agents::Runner.run(file_agent, "Please list the files in this directory")
puts result.output
```

### Multi-Agent Workflows with Shared MCP

Share MCP capabilities across multiple specialized agents:

```ruby
# Define shared MCP configuration
shared_mcp_config = {
  name: "filesystem",
  command: "npx",
  args: ["-y", "@modelcontextprotocol/server-filesystem", "."],
  include_tools: %w[read_file write_file list_directory]
}

# Research Agent - gathers information
research_agent = Agents::Agent.new(
  name: "Research Agent",
  instructions: <<~PROMPT,
    You specialize in gathering and organizing information.
    Focus on:
    1. Exploring project structures
    2. Reading relevant files
    3. Summarizing findings
    
    Hand off to Analysis Agent for code analysis or Writer Agent for documentation.
  PROMPT
  mcp_clients: [shared_mcp_config]
)

# Analysis Agent - analyzes code
analysis_agent = Agents::Agent.new(
  name: "Analysis Agent", 
  instructions: <<~PROMPT,
    You specialize in code analysis and architecture review.
    Focus on:
    1. Understanding code structure
    2. Identifying patterns and best practices
    3. Providing technical insights
    
    Hand off to Writer Agent for documentation or Research Agent for more information.
  PROMPT
  mcp_clients: [shared_mcp_config]
)

# Writer Agent - creates documentation
writer_agent = Agents::Agent.new(
  name: "Writer Agent",
  instructions: <<~PROMPT,
    You specialize in creating clear technical documentation.
    Focus on:
    1. Writing well-structured docs
    2. Creating helpful examples
    3. Organizing information logically
    
    Hand off to Research Agent for more info or Analysis Agent for technical details.
  PROMPT
  mcp_clients: [shared_mcp_config]
)

# Set up handoff relationships
research_agent.register_handoffs(analysis_agent, writer_agent)
analysis_agent.register_handoffs(writer_agent, research_agent)
writer_agent.register_handoffs(research_agent, analysis_agent)

# Execute workflow
result = Agents::Runner.run(
  research_agent,
  "Create comprehensive documentation for this project by exploring the codebase"
)
```

## Available MCP Servers

### Official Servers

Popular MCP servers from the Model Context Protocol ecosystem:

```bash
# Filesystem operations
npm install -g @modelcontextprotocol/server-filesystem

# Git operations  
npm install -g @modelcontextprotocol/server-git

# PostgreSQL database
npm install -g @modelcontextprotocol/server-postgres

# Google Drive integration
npm install -g @modelcontextprotocol/server-gdrive
```

### Using Official Servers

```ruby
# Filesystem server
filesystem_agent = Agents::Agent.new(
  name: "FileManager",
  instructions: "You can manage files and directories.",
  mcp_clients: [{
    name: "filesystem",
    command: "npx",
    args: ["-y", "@modelcontextprotocol/server-filesystem", "/workspace"]
  }]
)

# Git operations server
git_agent = Agents::Agent.new(
  name: "GitAssistant", 
  instructions: "You can help with Git operations and repository management.",
  mcp_clients: [{
    name: "git",
    command: "npx",
    args: ["-y", "@modelcontextprotocol/server-git", "--repository", "."]
  }]
)

# Database server (requires PostgreSQL)
db_agent = Agents::Agent.new(
  name: "DatabaseAgent",
  instructions: "You can query and manage database records.",
  mcp_clients: [{
    name: "postgres",
    command: "npx",
    args: ["-y", "@modelcontextprotocol/server-postgres"],
    env: {
      "POSTGRES_CONNECTION_STRING" => "postgresql://user:pass@localhost/db"
    }
  }]
)
```

## Creating Custom MCP Servers

### HTTP Server Example

Create a simple HTTP-based MCP server using Sinatra:

```ruby
# custom_mcp_server.rb
require "sinatra"
require "json"

# Configure server
set :port, 4568
set :bind, "127.0.0.1"

# Mock data
TASKS = [
  { id: 1, title: "Review PR", status: "pending" },
  { id: 2, title: "Write tests", status: "completed" }
]

# MCP JSON-RPC endpoint
post "/mcp" do
  content_type :json
  
  begin
    request_data = JSON.parse(request.body.read)
    method = request_data["method"]
    params = request_data["params"] || {}
    id = request_data["id"]
    
    result = case method
             when "tools/list"
               {
                 tools: [
                   {
                     name: "get_tasks",
                     description: "Get all tasks",
                     inputSchema: {
                       type: "object",
                       properties: {},
                       required: []
                     }
                   },
                   {
                     name: "create_task",
                     description: "Create a new task",
                     inputSchema: {
                       type: "object", 
                       properties: {
                         title: { type: "string", description: "Task title" },
                         status: { type: "string", description: "Task status" }
                       },
                       required: ["title"]
                     }
                   }
                 ]
               }
             when "tools/call"
               handle_tool_call(params)
             else
               { error: { code: -32601, message: "Method not found" } }
             end
    
    if result[:error]
      { jsonrpc: "2.0", error: result[:error], id: id }.to_json
    else
      { jsonrpc: "2.0", result: result, id: id }.to_json
    end
  rescue JSON::ParserError => e
    status 400
    { jsonrpc: "2.0", error: { code: -32700, message: "Parse error" }, id: nil }.to_json
  end
end

def handle_tool_call(params)
  case params["name"]
  when "get_tasks"
    {
      content: [{ type: "text", text: TASKS.to_json }],
      isError: false
    }
  when "create_task"
    new_task = {
      id: TASKS.length + 1,
      title: params.dig("arguments", "title"),
      status: params.dig("arguments", "status") || "pending"
    }
    TASKS << new_task
    {
      content: [{ type: "text", text: "Created: #{new_task.to_json}" }],
      isError: false
    }
  else
    { error: { code: -32601, message: "Unknown tool" } }
  end
end

puts "🚀 MCP Server running on http://localhost:4568"
```

Use the custom server with agents:

```ruby
# Start the server (in separate terminal): ruby custom_mcp_server.rb

# Create agent that uses custom MCP server
task_agent = Agents::Agent.new(
  name: "TaskManager",
  instructions: "You can manage tasks using the available tools.",
  mcp_clients: [{
    name: "task_server",
    url: "http://localhost:4568"
  }]
)

# Test the integration
result = Agents::Runner.run(task_agent, "Show me all current tasks")
puts result.output

result = Agents::Runner.run(task_agent, "Create a new task called 'Update documentation'")
puts result.output
```

## Security and Best Practices

### Tool Filtering

Always use tool filtering to limit agent capabilities:

```ruby
# GOOD: Restrict to safe operations
safe_client = Agents::MCP::Client.new(
  name: "filesystem",
  command: "npx",
  args: ["-y", "@modelcontextprotocol/server-filesystem", "/safe/directory"],
  include_tools: %w[read_file list_files],    # Read-only operations
  exclude_tools: %w[write_file delete_file]   # Block modifications
)

# BAD: No restrictions (potentially dangerous)
unsafe_client = Agents::MCP::Client.new(
  name: "filesystem",
  command: "npx", 
  args: ["-y", "@modelcontextprotocol/server-filesystem", "/"]
  # No filtering - agent has full filesystem access!
)
```

### Environment Isolation

Use restricted environments for MCP servers:

```ruby
# Isolate with environment variables
restricted_agent = Agents::Agent.new(
  name: "RestrictedAgent",
  mcp_clients: [{
    name: "database",
    command: "db-server",
    env: {
      "DB_READ_ONLY" => "true",
      "DB_TIMEOUT" => "30",
      "DB_MAX_ROWS" => "1000"
    }
  }]
)
```

### Error Handling

Implement robust error handling for MCP operations:

```ruby
# Check MCP client health before use
agent = Agents::Agent.new(
  name: "SafeAgent",
  instructions: "You can safely interact with external systems.",
  mcp_clients: [filesystem_config]
)

# Verify connections
health = agent.mcp_client_health
health.each do |client_name, status|
  unless status[:healthy]
    puts "⚠️  MCP client '#{client_name}' is unhealthy: #{status[:error]}"
    # Handle unhealthy clients appropriately
  end
end

# Run with error handling
begin
  result = Agents::Runner.run(agent, "List files in current directory")
  puts result.output
rescue Agents::MCP::ConnectionError => e
  puts "MCP connection failed: #{e.message}"
rescue Agents::MCP::ToolExecutionError => e
  puts "Tool execution failed: #{e.message}"
end
```

## Troubleshooting

### Common Issues

**MCP Server Not Found**
```bash
# Install required MCP server
npm install -g @modelcontextprotocol/server-filesystem

# Verify installation
npx @modelcontextprotocol/server-filesystem --help
```

**Connection Failures**
```ruby
# Check client health
health = agent.mcp_client_health
puts health

# Enable debug mode
Agents.configure do |config|
  config.debug = true
end
```

**Tool Filtering Issues**
```ruby
# List available tools to verify filtering
client = Agents::MCP::Client.new(name: "test", command: "server")
client.connect
tools = client.list_tools
puts "Available tools: #{tools.map(&:name)}"
```

### Debug Mode

Enable comprehensive debugging:

```ruby
# Enable global debug mode
Agents.configure do |config|
  config.debug = true
end

# Enable MCP-specific debugging
ENV["AGENTS_DEBUG"] = "true"

# Run agent with debug output
result = Agents::Runner.run(agent, "Your message here")
```

## Performance Considerations

### Connection Pooling

Reuse MCP clients across agents to reduce overhead:

```ruby
# Create shared MCP configuration
shared_config = {
  name: "shared_filesystem",
  command: "npx",
  args: ["-y", "@modelcontextprotocol/server-filesystem", "."]
}

# Use same config across multiple agents
agents = 3.times.map do |i|
  Agents::Agent.new(
    name: "Agent#{i}",
    instructions: "Specialized agent #{i}",
    mcp_clients: [shared_config]
  )
end
```

### Tool Caching

MCP clients automatically cache tool lists to improve performance:

```ruby
# First call discovers and caches tools
tools = client.list_tools

# Subsequent calls use cache
tools = client.list_tools  # Fast - uses cache

# Force refresh when needed
tools = client.list_tools(refresh: true)
```

### Timeout Configuration

Configure appropriate timeouts for MCP operations:

```ruby
client = Agents::MCP::Client.new(
  name: "slow_server",
  url: "http://slow-api.example.com",
  timeout: 60,  # 60 second timeout
  headers: { "X-Timeout" => "30" }
)
```

## Advanced Patterns

### Dynamic MCP Server Discovery

Dynamically add MCP clients based on runtime conditions:

```ruby
agent = Agents::Agent.new(
  name: "DynamicAgent",
  instructions: "I can adapt my capabilities based on available services."
)

# Add MCP clients conditionally
if filesystem_available?
  agent.add_mcp_clients({
    name: "filesystem",
    command: "npx",
    args: ["-y", "@modelcontextprotocol/server-filesystem", "."]
  })
end

if database_available?
  agent.add_mcp_clients({
    name: "database",
    url: "http://localhost:5432",
    headers: { "Authorization" => "Bearer #{db_token}" }
  })
end
```

### Context-Aware Tool Selection

Use dynamic instructions to guide tool usage:

```ruby
agent = Agents::Agent.new(
  name: "ContextAwareAgent",
  instructions: ->(context) {
    user_role = context[:user_role] || "guest"
    
    base_instructions = "You are a helpful assistant."
    
    case user_role
    when "admin"
      base_instructions + " You have full access to all tools including file management and database operations."
    when "user"
      base_instructions + " You can read files and query data but cannot make changes."
    else
      base_instructions + " You can only perform basic operations."
    end
  },
  mcp_clients: [
    {
      name: "filesystem",
      command: "filesystem-server",
      include_tools: user_role == "admin" ? nil : %w[read_file list_files]
    }
  ]
)
```

This comprehensive guide provides everything needed to integrate MCP servers with AI Agents, from basic setup to advanced patterns and security considerations.