$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))

require "agents"

# This example demonstrates multi-agent workflow with MCP tools
# Shows how multiple agents can work together using seamless handoffs
# Prerequisites: npm install -g @modelcontextprotocol/server-filesystem

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

# Create shared MCP client
FILESYSTEM_CLIENT = Agents::MCP::Client.new(
  name: "Filesystem",
  command: "npx", 
  args: ["-y", "@modelcontextprotocol/server-filesystem", Dir.home],
  cache_tools: true
)

# Define a context for sharing data between agents
class DocumentWorkflowContext < Agents::Context
  attr_accessor :document_content, :file_path, :analysis_result
end


# Document writer agent - creates files and reports using MCP
class DocumentWriterAgent < Agents::Agent  
  name "Document Writer Agent"
  instructions <<~PROMPT
    You are a document writing specialist. You can:
    1. Create new files using the filesystem tools
    2. Write reports based on analyzed content from context
    3. Save files to the filesystem
    
    Use context.document_content and context.analysis_result when available
    to inform your writing. Always confirm what files you've created.
  PROMPT

  mcp_clients FILESYSTEM_CLIENT
end


# Document reader agent - reads and analyzes files using MCP
class DocumentReaderAgent < Agents::Agent
  name "Document Reader Agent"
  instructions <<~PROMPT
    You are a document reading specialist. You can:
    1. Read files from the filesystem using available tools
    2. Analyze document content
    3. Store results in the shared context for other agents
    
    When you read a file, save its content to context.document_content
    and the file path to context.file_path for other agents to use.
  PROMPT

  mcp_clients FILESYSTEM_CLIENT
  handoffs DocumentWriterAgent
end


# Triage agent - decides which specialist to use
class DocumentTriageAgent < Agents::Agent
  name "Document Triage Agent"
  instructions <<~PROMPT
    You are a document workflow coordinator. Your job is to:
    1. Understand what the user wants to do with documents
    2. Route them to the appropriate specialist:
       - DocumentReaderAgent for reading/analyzing existing files
       - DocumentWriterAgent for creating new files or reports
    
    Always transfer to the appropriate specialist based on the user's request.
  PROMPT

  handoffs DocumentReaderAgent, DocumentWriterAgent
end

begin
  # Create shared context and runner
  context = DocumentWorkflowContext.new
  runner = Agents::Runner.new(
    initial_agent: DocumentTriageAgent,
    context: context
  )
  
  # Create a test file for the workflow
  test_file = File.join(Dir.home, "test_readme.md")
  File.write(test_file, <<~CONTENT)
    # Test Project
    
    This is a sample README file for testing the MCP multi-agent workflow.
    
    ## Features
    - Multi-agent orchestration
    - MCP tool integration
    - Seamless handoffs
    
    ## Usage
    The agents work together to process documents automatically.
  CONTENT

  puts "Created test file: #{test_file}"
  
  # Test the multi-agent workflow
  workflow_steps = [
    "Read the test_readme.md file in my home directory and analyze its content",
    "Create a summary report based on what you read"
  ]

  workflow_steps.each do |step|
    puts "\nUser: #{step}"
    
    begin
      response = runner.process(step)
      puts "Response: #{response}"
      
      # Show agent transitions if any occurred
      if context.agent_transitions.any?
        puts "Agent transitions:"
        context.agent_transitions.each do |transition|
          puts "  #{transition[:from]} → #{transition[:to]}"
        end
      end
      
    rescue StandardError => e
      puts "Error: #{e.message}"
    end
    puts "-" * 50
  end

rescue Agents::MCP::Error => e
  puts "MCP Error: #{e.message}"
  puts "Make sure you have the filesystem MCP server available:"
  puts "npm install -g @modelcontextprotocol/server-filesystem"
rescue StandardError => e
  puts "Error: #{e.message}"
ensure
  FILESYSTEM_CLIENT&.disconnect if FILESYSTEM_CLIENT&.connected?
  
  # Clean up test file
  test_file = File.join(Dir.home, "test_readme.md")
  File.delete(test_file) if File.exist?(test_file)
end

puts "\nMulti-agent MCP workflow example completed!"