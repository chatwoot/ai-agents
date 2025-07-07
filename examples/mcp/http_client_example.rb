#!/usr/bin/env ruby
# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))

require "agents"

# Production MCP HTTP client integration
# Demonstrates how to create an agent with HTTP MCP capabilities
class MCPHTTPClient
  def self.create_agent
    # Configure the agents system
    Agents.configure do |config|
      config.openai_api_key = ENV["OPENAI_API_KEY"]
      config.default_model = "gpt-4o-mini"
      config.debug = ENV["AGENTS_DEBUG"] == "true"
    end

    raise "OPENAI_API_KEY environment variable is required" unless Agents.configuration.configured?

    # Test HTTP server connectivity
    test_server_connectivity

    # Create agent with HTTP MCP client configuration
    mcp_config = {
      name: "api_server",
      url: "http://localhost:4568",
      headers: {
        "Content-Type" => "application/json",
        "User-Agent" => "Ruby-Agents-MCP/1.0"
      }
    }

    Agents::Agent.new(
      name: "API Assistant",
      instructions: <<~INSTRUCTIONS,
        You are a helpful API assistant that can interact with a user database.
        You have access to tools that can get users, get specific users by ID, and create new users.

        Always be helpful and explain what data you're retrieving or creating.
        When showing user data, format it nicely for the user.
      INSTRUCTIONS
      mcp_clients: [mcp_config]
    )
  end

  def self.test_server_connectivity
    require "net/http"
    require "json"

    uri = URI("http://localhost:4568/health")
    response = Net::HTTP.get_response(uri)

    raise "HTTP server not available (status: #{response.code})" unless response.code.to_i == 200
  rescue StandardError => e
    raise "Cannot connect to HTTP server: #{e.message}. Make sure to start the server first."
  end

  def self.run_scenarios(agent)
    scenarios = [
      "Use the get_users tool to get all users from the database and show them in a nice format",
      "Use the get_user tool to get the user with ID 2 and tell me about them"
    ]

    results = []

    scenarios.each do |scenario|
      result = Agents::Runner.run(agent, scenario)
      results << {
        scenario: scenario,
        output: result.output,
        error: result.error
      }
    end

    results
  end

  def self.run_example
    agent = create_agent

    # Ensure tools are loaded
    agent.all_tools

    # Run test scenarios
    run_scenarios(agent)
  end
end

# Run the example if this file is executed directly
if __FILE__ == $0
  begin
    results = MCPHTTPClient.run_example

    results.each_with_index do |result, i|
      puts "\nScenario #{i + 1}: #{result[:scenario]}"
      puts "Response: #{result[:output]}" if result[:output]
      puts "Error: #{result[:error].message}" if result[:error]
    end
  rescue StandardError => e
    puts "Error: #{e.message}"
    exit 1
  end
end
