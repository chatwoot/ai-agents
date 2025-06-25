#!/usr/bin/env ruby
# Simple HTTP MCP Server for testing HTTP transport
# This creates a basic MCP server that responds to HTTP requests

require 'sinatra'
require 'json'

# Configure Sinatra to run on a specific port
set :port, 3001
set :bind, '0.0.0.0'

# Simple in-memory data for demonstration
SAMPLE_DATA = {
  users: [
    { id: 1, name: "Alice", email: "alice@example.com" },
    { id: 2, name: "Bob", email: "bob@example.com" },
    { id: 3, name: "Charlie", email: "charlie@example.com" }
  ],
  tasks: [
    { id: 1, title: "Review code", status: "pending", user_id: 1 },
    { id: 2, title: "Write tests", status: "completed", user_id: 2 },
    { id: 3, title: "Deploy app", status: "in_progress", user_id: 1 }
  ]
}

# MCP Protocol implementation
class MCPServer
  def self.handle_request(request_data)
    method = request_data['method']
    params = request_data['params'] || {}
    id = request_data['id']

    case method
    when 'tools/list'
      {
        jsonrpc: "2.0",
        id: id,
        result: {
          tools: [
            {
              name: "get_users",
              description: "Get all users from the database",
              inputSchema: {
                type: "object",
                properties: {},
                required: []
              }
            },
            {
              name: "get_user_by_id", 
              description: "Get a specific user by ID",
              inputSchema: {
                type: "object",
                properties: {
                  user_id: { type: "integer", description: "User ID to retrieve" }
                },
                required: ["user_id"]
              }
            },
            {
              name: "get_tasks",
              description: "Get all tasks, optionally filtered by user",
              inputSchema: {
                type: "object", 
                properties: {
                  user_id: { type: "integer", description: "Filter tasks by user ID" },
                  status: { 
                    type: "string", 
                    description: "Filter tasks by status",
                    enum: ["pending", "in_progress", "completed"]
                  }
                },
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
                  user_id: { type: "integer", description: "Assigned user ID" },
                  status: { 
                    type: "string", 
                    description: "Task status",
                    enum: ["pending", "in_progress", "completed"]
                  }
                },
                required: ["title", "user_id"]
              }
            }
          ]
        }
      }

    when 'tools/call'
      tool_name = params['name']
      arguments = params['arguments'] || {}
      
      case tool_name
      when 'get_users'
        {
          jsonrpc: "2.0",
          id: id,
          result: {
            content: [
              {
                type: "text",
                text: JSON.pretty_generate(SAMPLE_DATA[:users])
              }
            ]
          }
        }

      when 'get_user_by_id'
        user_id = arguments['user_id']
        user = SAMPLE_DATA[:users].find { |u| u[:id] == user_id }
        
        if user
          {
            jsonrpc: "2.0",
            id: id,
            result: {
              content: [
                {
                  type: "text", 
                  text: JSON.pretty_generate(user)
                }
              ]
            }
          }
        else
          {
            jsonrpc: "2.0",
            id: id,
            result: {
              isError: true,
              content: [
                {
                  type: "text",
                  text: "User with ID #{user_id} not found"
                }
              ]
            }
          }
        end

      when 'get_tasks'
        tasks = SAMPLE_DATA[:tasks]
        
        # Filter by user_id if provided
        if arguments['user_id']
          tasks = tasks.select { |t| t[:user_id] == arguments['user_id'] }
        end
        
        # Filter by status if provided  
        if arguments['status']
          tasks = tasks.select { |t| t[:status] == arguments['status'] }
        end
        
        {
          jsonrpc: "2.0",
          id: id,
          result: {
            content: [
              {
                type: "text",
                text: JSON.pretty_generate(tasks)
              }
            ]
          }
        }

      when 'create_task'
        new_id = SAMPLE_DATA[:tasks].map { |t| t[:id] }.max + 1
        new_task = {
          id: new_id,
          title: arguments['title'],
          user_id: arguments['user_id'],
          status: arguments['status'] || 'pending'
        }
        
        SAMPLE_DATA[:tasks] << new_task
        
        {
          jsonrpc: "2.0", 
          id: id,
          result: {
            content: [
              {
                type: "text",
                text: "Created task: #{JSON.pretty_generate(new_task)}"
              }
            ]
          }
        }

      else
        {
          jsonrpc: "2.0",
          id: id,
          error: {
            code: -32601,
            message: "Method not found: #{tool_name}"
          }
        }
      end

    else
      {
        jsonrpc: "2.0",
        id: id,
        error: {
          code: -32601, 
          message: "Method not found: #{method}"
        }
      }
    end
  end
end

# MCP Protocol endpoints - both styles supported
['/mcp', '/tools', '/tools/call'].each do |endpoint|
  post endpoint do
    content_type :json
    
    begin
      request_data = JSON.parse(request.body.read)
      puts "Received MCP request at #{endpoint}: #{request_data.inspect}"
      
      response = MCPServer.handle_request(request_data)
      puts "Sending MCP response: #{response.inspect}"
      
      response.to_json
      
    rescue JSON::ParserError => e
      status 400
      { error: "Invalid JSON: #{e.message}" }.to_json
      
    rescue StandardError => e
      status 500
      { error: "Server error: #{e.message}" }.to_json
    end
  end
end

# Health check endpoint
get '/health' do
  content_type :json
  { status: "ok", timestamp: Time.now.iso8601 }.to_json
end

# Root endpoint with server info
get '/' do
  content_type :json
  {
    name: "Simple HTTP MCP Server",
    version: "1.0.0",
    description: "A basic MCP server for testing HTTP transport",
    endpoints: {
      mcp: "/mcp",
      health: "/health"
    },
    sample_tools: ["get_users", "get_user_by_id", "get_tasks", "create_task"]
  }.to_json
end

puts "Starting Simple HTTP MCP Server on http://localhost:3001"
puts "MCP endpoint: http://localhost:3001/mcp"
puts "Health check: http://localhost:3001/health"
puts "Press Ctrl+C to stop"