# frozen_string_literal: true

# Model Context Protocol (MCP) integration for Ruby Agents SDK.
# This module provides the ability to connect to external MCP servers and use their tools
# dynamically within agent workflows, enabling agents to access external resources
# and capabilities through the standardized MCP protocol.
#
# @example Connecting to a filesystem MCP server
#   client = Agents::MCP::Client.new(
#     name: "filesystem",
#     command: "npx",
#     args: ["-y", "@modelcontextprotocol/server-filesystem", "."]
#   )
#
#   agent = Agents::Agent.new(
#     name: "File Assistant",
#     instructions: "Help users with file operations",
#     mcp_clients: [client]
#   )
#
# @example Connecting to an HTTP MCP server
#   client = Agents::MCP::Client.new(
#     name: "api_server",
#     url: "http://localhost:8000",
    #     headers: { "X-Custom-Header" => "value" }
#   )
module Agents
  module MCP
    # Base error class for all MCP-related errors
    class Error < StandardError; end

    # Raised when connection to MCP server fails
    class ConnectionError < Error; end

    # Raised when MCP protocol parsing or communication fails
    class ProtocolError < Error; end

    # Raised when MCP server returns an error response
    class ServerError < Error; end
  end
end

# Load MCP components
require_relative "mcp/client"
require_relative "mcp/stdio_transport"
require_relative "mcp/http_transport"
require_relative "mcp/sse_transport"
require_relative "mcp/tool"
require_relative "mcp/tool_result"
require_relative "mcp/manager"
