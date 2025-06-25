$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))

require "agents"

# Configure the Ruby Agents SDK
Agents.configure do |config|
  config.openai_api_key = ENV["OPENAI_API_KEY"]
  config.default_model = "gpt-4o-mini"
end

# Check if we're properly configured
unless Agents.configuration.configured?
  puts "No API keys configured. Please set OPENAI_API_KEY environment variable."
  puts "Example: export OPENAI_API_KEY=your_key_here"
  exit 1
end

# Create the MCP client first
MINTLIFY_CLIENT = Agents::MCP::Client.new(
  name: "Mintlify",
  command: "node",
  args: ["/Users/tanmaydeepsharma/.mcp/acme-d0cb791b/src/index.js"],
  cache_tools: true  # Cache tools since Mintlify tools are typically static
)

# Define a documentation agent that uses Mintlify tools
class DocumentationAgent < Agents::Agent
  name "Documentation Assistant"
  instructions <<~PROMPT
    You are a helpful documentation assistant with access to Chatwoot's documentation and API tools.
    
    You can:
    1. Search documentation to answer questions about features, setup, and usage
    2. Execute API operations to retrieve or manage data
    3. Help users understand technical concepts and provide examples
    
    When users ask questions:
    - For general information about how something works, use the 'search' tool
    - For specific data retrieval or API operations, use the appropriate API tools
    - Always extract parameters from the user's request and use the correct data types
    - If required parameters are missing, ask the user to provide them
    
    Use the available tools based on what the user wants to accomplish. Each tool has its own parameter requirements that you should follow.
  PROMPT

  mcp_clients MINTLIFY_CLIENT
end

begin
  agent = DocumentationAgent.new
  # Test queries for documentation assistance
  test_queries = [
    "What is the private note in conversation id 25?",
    "Search for information about API authentication in the documentation",
    "What are the rate limits for API calls?"
  ]

  test_queries.each_with_index do |query, i|
    puts "User: #{query}"
    
    begin
      response = agent.call(query)
      puts "Response from agent: #{response.content}"
    rescue StandardError => e
      puts "Error: #{e.message}"
    end
    puts "-" * 50
    puts
  end


  # Test tools listing and direct tool usage
  MINTLIFY_CLIENT.connect
  tools = MINTLIFY_CLIENT.list_tools
  puts "Count of Available Mintlify tools: #{tools.count}"

  puts "Direct tool usage from Mintlify MCP..."
  sample_params = {
    query: "How do I get started with the platform?",
    limit: 2
  }      
  result = MINTLIFY_CLIENT.call_tool("search", sample_params)
  puts "   Result: #{result}"
end
