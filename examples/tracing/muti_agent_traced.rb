# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))

require "agents"

# This example demonstrates a sophisticated multi-agent workflow using Mintlify MCP
# with multiple specialized agents working together with shared context

# Configure the Ruby Agents SDK
Agents.configure do |config|
  config.openai_api_key = ENV["OPENAI_API_KEY"]
  config.default_model = "gpt-4o-mini"
  # Enable comprehensive tracing
  config.tracing.enabled = true
  config.tracing.export_path = "./booking_traces"
  config.tracing.include_sensitive_data = true
end

unless Agents.configuration.configured?
  puts "No API keys configured. Please set OPENAI_API_KEY environment variable."
  puts "Example: export OPENAI_API_KEY=your_key_here"
  exit 1
end

# Create shared MCP clients
MINTLIFY_CLIENT = Agents::MCP::Client.new(
  name: "Mintlify",
  command: "node",
  args: ["/Users/tanmaydeepsharma/.mcp/acme-d0cb791b/src/index.js"],
  cache_tools: true
)

FILESYSTEM_CLIENT = Agents::MCP::Client.new(
  name: "Filesystem",
  command: "npx",
  args: ["-y", "@modelcontextprotocol/server-filesystem", Dir.home],
  cache_tools: true
)

# Define a shared context for the documentation workflow
class DocumentationWorkflowContext < Agents::Context
  attr_accessor :search_results, :documentation_topic, :generated_content, :saved_files

  def initialize
    super
    @saved_files = []
  end
end

# Editor agent - refines and saves documentation
class DocumentationEditorAgent < Agents::Agent
  name "Documentation Editor"
  instructions <<~PROMPT
    You are a documentation editor and file manager. Your responsibilities:
    1. Review and improve generated documentation from context.generated_content
    2. Save documentation to files using filesystem tools
    3. Organize and structure documentation projects
    4. Provide final polished output

    Use the filesystem tools to save content to appropriate files in the user's home directory.
    Provide clear feedback about what files were created and their contents.
  PROMPT

  mcp_clients FILESYSTEM_CLIENT, MINTLIFY_CLIENT
end

# Generator agent - creates new documentation
class DocumentationGeneratorAgent < Agents::Agent
  name "Documentation Generator"
  instructions <<~PROMPT
    You are a documentation generation specialist. You create high-quality
    technical documentation based on:
    1. Information from previous search results (context.search_results)
    2. User requirements and specifications
    3. Best practices for technical writing

    After generating documentation:
    1. Save it to context.generated_content for other agents to use
    2. Create a file using the filesystem tools in the user's home directory
    3. Use an appropriate filename like "api_authentication_guide.md" or "rate_limiting_guide.md"
    4. Use the write_file tool with just the filename (e.g., "api_authentication_guide.md")
    5. Add the filename to context.saved_files array
    6. Confirm what file was created and where it was saved

    IMPORTANT: The filesystem server is configured for /Users/tanmaydeepsharma, so just use relative filenames like "api_authentication_guide.md" without any path prefix.
  PROMPT

  mcp_clients MINTLIFY_CLIENT, FILESYSTEM_CLIENT
  handoffs DocumentationEditorAgent
end

# Search agent - finds relevant documentation using Mintlify
class DocumentationSearchAgent < Agents::Agent
  name "Documentation Search Specialist"
  instructions <<~PROMPT
    You are a documentation search expert using Mintlify. Your role is to:
    1. Search through documentation using Mintlify tools
    2. Find the most relevant information for user queries
    3. Store search results in the shared context
    4. Summarize findings and suggest next steps

    When you find relevant documentation, save the results to context.search_results
    and set context.documentation_topic to describe what was found.

    If the user needs to create new documentation, transfer to DocumentationGeneratorAgent.
  PROMPT

  mcp_clients MINTLIFY_CLIENT
  handoffs DocumentationGeneratorAgent
end

# Triage agent - routes documentation requests
class DocumentationTriageAgent < Agents::Agent
  name "Documentation Triage"
  instructions <<~PROMPT
    You are a documentation workflow coordinator. Your job is to:
    1. Understand what kind of documentation help the user needs
    2. Route them to the appropriate specialist:
       - DocumentationSearchAgent for finding existing documentation
       - DocumentationGeneratorAgent for creating new documentation

    Analyze the user's request and transfer to the most appropriate agent.
  PROMPT

  handoffs DocumentationSearchAgent, DocumentationGeneratorAgent, DocumentationEditorAgent
end

begin
  # Create shared context and runner
  context = DocumentationWorkflowContext.new
  runner = Agents::Runner.new(
    initial_agent: DocumentationTriageAgent,
    context: context
  )

  # Test workflow scenarios
  workflow_scenarios = [
    "I need to understand how authentication works in our API. Can you find the documentation and create a simple guide?",
    "Find information about rate limiting and generate a troubleshooting guide for developers"
  ]

  workflow_scenarios.each_with_index do |scenario, i|
    puts "#{i + 1}. User: #{scenario}"

    begin
      response = runner.process(scenario)
      puts "Final Result: #{response}"

      # Show workflow details
      if context.agent_transitions.any?
        puts "Agent workflow:"
        context.agent_transitions.each do |transition|
          puts "  #{transition[:from]} → #{transition[:to]}"
        end
      end

      # Show saved files
      if context.saved_files.any?
        puts "Files saved:"
        context.saved_files.each do |file|
          puts "  📄 #{file}"
        end
      end
    rescue StandardError => e
      puts "Error in workflow: #{e.message}"
    end

    puts "-" * 50
    puts

    # Reset context for next scenario
    context = DocumentationWorkflowContext.new
    runner = Agents::Runner.new(
      initial_agent: DocumentationTriageAgent,
      context: context
    )
  end
rescue Agents::MCP::ConnectionError => e
  puts "Failed to connect to MCP servers: #{e.message}"
  puts "Setup Instructions:"
  puts "1. Install Mintlify MCP: npx mint-mcp add acme-d0cb791b"
  puts "2. Install filesystem server: npm install -g @modelcontextprotocol/server-filesystem"
rescue StandardError => e
  puts "Error: #{e.message}"
ensure
  MINTLIFY_CLIENT&.disconnect if MINTLIFY_CLIENT&.connected?
  FILESYSTEM_CLIENT&.disconnect if FILESYSTEM_CLIENT&.connected?
end

puts "Mintlify multi-agent workflow completed!"
