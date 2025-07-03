#!/usr/bin/env ruby
# frozen_string_literal: true

# Example HTTP MCP server for testing HTTP transport
# This creates a simple Sinatra-based MCP server that provides basic API tools
# Run this script to start the server, then use http_client_example.rb to test

require "sinatra"
require "json"

# Configure Sinatra
set :port, 4568
set :bind, "127.0.0.1"

# Mock database
USERS = [
  { id: 1, name: "Alice", email: "alice@example.com" },
  { id: 2, name: "Bob", email: "bob@example.com" },
  { id: 3, name: "Charlie", email: "charlie@example.com" }
].freeze

# Root endpoint
get "/" do
  content_type :json
  { message: "MCP Test Server", version: "1.0" }.to_json
end

# List available tools
get "/tools" do
  content_type :json

  {
    jsonrpc: "2.0",
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
          name: "get_user",
          description: "Get a specific user by ID",
          inputSchema: {
            type: "object",
            properties: {
              id: { type: "integer", description: "User ID" }
            },
            required: ["id"]
          }
        },
        {
          name: "create_user",
          description: "Create a new user",
          inputSchema: {
            type: "object",
            properties: {
              name: { type: "string", description: "User name" },
              email: { type: "string", description: "User email" }
            },
            required: %w[name email]
          }
        }
      ]
    }
  }.to_json
end

# Helper method to handle tool calls
def handle_tool_call(params)
  tool_name = params["name"]
  arguments = params["arguments"] || {}

  case tool_name
  when "get_users"
    {
      content: [
        {
          type: "text",
          text: USERS.to_json
        }
      ],
      isError: false
    }
  when "get_user"
    user_id = arguments["id"]
    # Convert to integer if it's a string
    user_id = user_id.to_i if user_id.is_a?(String)
    user = USERS.find { |u| u[:id] == user_id }

    if user
      {
        content: [
          {
            type: "text",
            text: user.to_json
          }
        ],
        isError: false
      }
    else
      {
        content: [
          {
            type: "text",
            text: "User with ID #{user_id} not found"
          }
        ],
        isError: true
      }
    end
  when "create_user"
    new_id = USERS.map { |u| u[:id] }.max + 1
    new_user = {
      id: new_id,
      name: arguments["name"],
      email: arguments["email"]
    }

    {
      content: [
        {
          type: "text",
          text: "Created user: #{new_user.to_json}"
        }
      ],
      isError: false
    }
  else
    {
      error: {
        code: -32601,
        message: "Unknown tool: #{tool_name}"
      }
    }
  end
end

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
                     name: "get_users",
                     description: "Get all users from the database",
                     inputSchema: {
                       type: "object",
                       properties: {},
                       required: []
                     }
                   },
                   {
                     name: "get_user", 
                     description: "Get a specific user by ID",
                     inputSchema: {
                       type: "object",
                       properties: {
                         id: { type: "integer", description: "User ID" }
                       },
                       required: ["id"]
                     }
                   },
                   {
                     name: "create_user",
                     description: "Create a new user", 
                     inputSchema: {
                       type: "object",
                       properties: {
                         name: { type: "string", description: "User name" },
                         email: { type: "string", description: "User email" }
                       },
                       required: %w[name email]
                     }
                   }
                 ]
               }
             when "tools/call"
               handle_tool_call(params)
             else
               {
                 error: {
                   code: -32601,
                   message: "Method not found: #{method}"
                 }
               }
             end

    if result[:error]
      {
        jsonrpc: "2.0",
        error: result[:error],
        id: id
      }.to_json
    else
      {
        jsonrpc: "2.0",
        result: result,
        id: id
      }.to_json
    end
  rescue JSON::ParserError => e
    status 400
    {
      jsonrpc: "2.0",
      error: {
        code: -32700,
        message: "Parse error: #{e.message}"
      },
      id: nil
    }.to_json
  rescue StandardError => e
    status 500
    {
      jsonrpc: "2.0",
      error: {
        code: -32603,
        message: "Internal error: #{e.message}"
      },
      id: request_data&.dig("id")
    }.to_json
  end
end

# Call a tool (backward compatibility)
post "/tools/call" do
  content_type :json

  begin
    request_data = JSON.parse(request.body.read)
    tool_name = request_data.dig("params", "name")
    arguments = request_data.dig("params", "arguments") || {}

    result = case tool_name
             when "get_users"
               {
                 content: [
                   {
                     type: "text",
                     text: USERS.to_json
                   }
                 ],
                 isError: false
               }
             when "get_user"
               user_id = arguments["id"]
               # Convert to integer if it's a string
               user_id = user_id.to_i if user_id.is_a?(String)
               user = USERS.find { |u| u[:id] == user_id }

               if user
                 {
                   content: [
                     {
                       type: "text",
                       text: user.to_json
                     }
                   ],
                   isError: false
                 }
               else
                 {
                   content: [
                     {
                       type: "text",
                       text: "User with ID #{user_id} not found"
                     }
                   ],
                   isError: true
                 }
               end
             when "create_user"
               new_id = USERS.map { |u| u[:id] }.max + 1
               new_user = {
                 id: new_id,
                 name: arguments["name"],
                 email: arguments["email"]
               }

               {
                 content: [
                   {
                     type: "text",
                     text: "Created user: #{new_user.to_json}"
                   }
                 ],
                 isError: false
               }
             else
               {
                 content: [
                   {
                     type: "text",
                     text: "Unknown tool: #{tool_name}"
                   }
                 ],
                 isError: true
               }
             end

    {
      id: request_data["id"],
      result: result
    }.to_json
  rescue JSON::ParserError => e
    status 400
    { error: "Invalid JSON: #{e.message}" }.to_json
  rescue StandardError => e
    status 500
    { error: "Internal error: #{e.message}" }.to_json
  end
end

# Health check
get "/health" do
  content_type :json
  { status: "ok", timestamp: Time.now.iso8601 }.to_json
end

if __FILE__ == $0
  puts "🚀 Starting MCP HTTP test server on http://localhost:4568"
  puts "📚 Available endpoints:"
  puts "   GET  /        - Server info"
  puts "   GET  /tools   - List available tools"
  puts "   POST /mcp      - MCP JSON-RPC endpoint (recommended)"
  puts "   POST /tools/call - Call a tool (backward compatibility)"
  puts "   GET  /health  - Health check"
  puts ""
  puts "🧪 Test with: ruby http_client_example.rb"
  puts "🛑 Press Ctrl+C to stop"
end
