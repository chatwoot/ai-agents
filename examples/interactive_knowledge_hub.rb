#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../lib/agents"
require_relative "../lib/agents/mcp/client"
require_relative "../lib/agents/mcp/tool_registry"
require_relative "../lib/agents/guardrails/simple_guardrails"

# Configure the SDK
Agents.configure do |config|
  config.openai_api_key = ENV['OPENAI_API_KEY']
  config.default_provider = :openai
  config.default_model = "gpt-4o-mini"
  config.debug = false
end

# Calculator tool for mathematical operations
class CalculatorTool < Agents::ToolBase
  name "calculate"
  description "Perform mathematical calculations and solve equations"
  param :expression, "string", "Mathematical expression to evaluate", required: true

  def perform(expression:, context: nil)
    begin
      # Simple safe evaluation for basic math
      sanitized = expression.gsub(/[^0-9+\-*\/\.\(\)\s]/, '')
      result = eval(sanitized)
      "📊 Calculation: #{expression} = #{result}"
    rescue => e
      "❌ Calculation error: #{e.message}. Please check your expression."
    end
  end
end

# Enhanced context that manages multiple MCP clients
class KnowledgeHubContext < Agents::Context
  attr_accessor :mcp_clients, :session_stats

  def initialize(data = {})
    super(data)
    @mcp_clients = {}
    @session_stats = {
      queries_processed: 0,
      docs_searched: 0,
      web_searches: 0,
      calculations: 0
    }
    setup_mcp_clients
  end

  def setup_mcp_clients
    # Clear any existing tools
    Agents::MCP::ToolRegistry.clear
    
    setup_mintlify_client
    setup_websearch_client
    
    # Store in context data for tool access
    self[:mcp_clients] = @mcp_clients
    
    # Display discovered tools summary
    display_discovered_tools
  end

  def setup_mintlify_client
    mcp_config = {
      'type' => 'stdio',
      'command' => File.expand_path('../bin/mintlify-mcp-server', __dir__),
      'args' => []
    }
    
    begin
      client = Agents::MCP::Client.new(mcp_config)
      client.connect
      @mcp_clients[:mintlify] = client
      
      # Register client and discover tools dynamically
      Agents::MCP::ToolRegistry.register_client(:mintlify, client)
      puts "✅ Connected to Mintlify Documentation MCP"
    rescue => e
      puts "⚠️  Mintlify MCP unavailable: #{e.message}"
      @mcp_clients[:mintlify] = nil
    end
  end

  def setup_websearch_client
    mcp_config = {
      'type' => 'stdio',
      'command' => File.expand_path('../bin/websearch-mcp-server', __dir__),
      'args' => []
    }
    
    begin
      client = Agents::MCP::Client.new(mcp_config)
      client.connect
      @mcp_clients[:websearch] = client
      
      # Register client and discover tools dynamically
      Agents::MCP::ToolRegistry.register_client(:websearch, client)
      puts "✅ Connected to WebSearch MCP"
    rescue => e
      puts "⚠️  WebSearch MCP unavailable: #{e.message}"
      @mcp_clients[:websearch] = nil
    end
  end

  def display_discovered_tools
    summary = Agents::MCP::ToolRegistry.summary
    return if summary[:total_tools] == 0
    
    puts "\n🔧 Dynamically Discovered Tools:"
    summary[:clients].each do |client_name, client_data|
      puts "  #{client_name}: #{client_data[:tool_count]} tools"
      client_data[:tools].each do |tool|
        puts "    • #{tool[:name]} - #{tool[:description]}"
      end
    end
  end

  def mintlify_connected?
    @mcp_clients[:mintlify] && @mcp_clients[:mintlify].healthy?
  end

  def websearch_connected?
    @mcp_clients[:websearch] && @mcp_clients[:websearch].healthy?
  end

  def increment_stat(stat_name)
    @session_stats[stat_name] += 1 if @session_stats.key?(stat_name)
    @session_stats[:queries_processed] += 1
  end
end

# Base agent class that dynamically uses available MCP tools
class DynamicMCPAgent < Agents::Agent
  def self.inherited(subclass)
    super
    # Automatically add available tools when the agent is defined
    subclass.define_singleton_method(:setup_dynamic_tools) do
      available_tools = Agents::MCP::ToolRegistry.available_tools
      tools_for_agent = available_tools.select { |tool| matches_agent_purpose?(tool, subclass.name) }
      
      tools_for_agent.each do |tool|
        uses tool.class
      end
    end
  end

  private

  def self.matches_agent_purpose?(tool, agent_name)
    case agent_name
    when /Documentation/
      tool.mcp_tool_name.include?('doc') || tool.mcp_tool_name.include?('search_docs') || tool.mcp_tool_name.include?('navigation')
    when /WebSearch/
      tool.mcp_tool_name.include?('web') || tool.mcp_tool_name.include?('search') || tool.mcp_tool_name.include?('news')
    else
      false
    end
  end
end

# Specialized agents with guardrails and dynamic tool discovery
class DocumentationAgent < Agents::Agent
  name "Documentation Expert"
  instructions <<~PROMPT
    You are a documentation expert specializing in finding and explaining information from official documentation.
    
    You have access to dynamically discovered documentation tools. When users ask about:
    - API documentation, guides, tutorials
    - Platform features, integrations
    - Getting started guides
    - Technical specifications
    
    Use the available documentation tools to find accurate, up-to-date information.
    Always provide clear explanations and direct users to relevant documentation sections.
  PROMPT

  # Input guardrail to ensure documentation-related queries
  def self.input_guardrail(message, context)
    # Allow documentation-related terms
    doc_terms = ['api', 'doc', 'guide', 'tutorial', 'integration', 'auth', 'webhook', 'endpoint', 'reference']
    message_lower = message.downcase
    
    # Check if message contains documentation-related terms
    has_doc_terms = doc_terms.any? { |term| message_lower.include?(term) }
    
    # Also allow if explicitly asking for documentation
    explicit_doc_request = message_lower.include?('documentation') || 
                          message_lower.include?('docs') ||
                          message_lower.include?('how to') ||
                          message_lower.include?('search')
    
    if has_doc_terms || explicit_doc_request
      { allowed: true }
    else
      { 
        allowed: false, 
        reason: "This agent specializes in documentation. Try asking about APIs, guides, tutorials, or integrations.",
        suggested_rephrase: "Try: 'Search for #{message.split.first} documentation' or 'How do I #{message.downcase}?'"
      }
    end
  end

  # Output guardrail to ensure helpful documentation responses
  def self.output_guardrail(response, context)
    # Ensure response contains useful documentation information
    if response.length < 20
      { 
        allowed: false, 
        reason: "Response too brief for documentation query",
        enhanced_response: "I found some documentation, but let me provide more details: #{response}"
      }
    elsif !response.include?('documentation') && !response.include?('docs') && !response.include?('📚')
      {
        allowed: true,
        enhanced_response: "📚 Documentation Search: #{response}"
      }
    else
      { allowed: true }
    end
  end

  # Dynamically use discovered documentation tools
  def initialize(context: {})
    super(context: context)
    setup_tools_from_registry(:mintlify)
  end

  private

  def setup_tools_from_registry(client_name)
    tools = Agents::MCP::ToolRegistry.tools_for_client(client_name)
    tools.each do |tool|
      if tool.mcp_tool_name.match?(/doc|search|navigation/)
        # Add the dynamic tool instance directly
        @dynamic_tools ||= []
        @dynamic_tools << tool
      end
    end
  end
end

class WebSearchAgent < Agents::Agent
  name "Web Research Specialist" 
  instructions <<~PROMPT
    You are a web research specialist who finds current information from across the internet.
    
    Use dynamically discovered web search tools to find:
    - Current news and trending topics
    - Recent developments and updates
    - General information not in documentation
    - Comparative analysis and reviews
    - Real-world examples and case studies
    
    Always verify information from multiple sources when possible and provide context about recency.
  PROMPT

  # Input guardrail for appropriate web search queries
  def self.input_guardrail(message, context)
    # Block potentially harmful or inappropriate searches
    blocked_terms = ['illegal', 'hack', 'exploit', 'vulnerability', 'password', 'private']
    message_lower = message.downcase
    
    if blocked_terms.any? { |term| message_lower.include?(term) }
      { 
        allowed: false, 
        reason: "Cannot search for potentially harmful or security-sensitive content.",
        suggested_rephrase: "Try searching for general information or recent news instead."
      }
    else
      { allowed: true }
    end
  end

  # Output guardrail to add context about search results
  def self.output_guardrail(response, context)
    # Add timestamp and disclaimer to web search results
    enhanced_response = response
    unless response.include?('🌐') || response.include?('📰')
      enhanced_response = "🌐 Web Search Results: #{response}"
    end
    
    unless response.include?('Note:') || response.include?('Disclaimer:')
      enhanced_response += "\n\n💡 Note: These are simulated search results for demonstration. In production, this would show real web data."
    end
    
    { allowed: true, enhanced_response: enhanced_response }
  end

  def initialize(context: {})
    super(context: context)
    setup_tools_from_registry(:websearch)
  end

  private

  def setup_tools_from_registry(client_name)
    tools = Agents::MCP::ToolRegistry.tools_for_client(client_name)
    tools.each do |tool|
      if tool.mcp_tool_name.match?(/web|search|news/)
        # Add the dynamic tool instance directly
        @dynamic_tools ||= []
        @dynamic_tools << tool
      end
    end
  end
end

class CalculatorAgent < Agents::Agent
  name "Mathematics Expert"
  instructions <<~PROMPT
    You are a mathematics expert who helps with calculations, equations, and numerical analysis.
    
    You can help with:
    - Basic arithmetic and complex calculations
    - Mathematical expressions and equations
    - Unit conversions and comparisons
    - Statistical analysis and percentages
    - Financial calculations
    
    Always show your work and explain the calculation process when helpful.
  PROMPT

  # Input guardrail for mathematical expressions
  def self.input_guardrail(message, context)
    # Check if message contains mathematical content
    math_indicators = ['+', '-', '*', '/', '=', '%', 'calculate', 'math', 'equation', 'number', /\d/]
    
    has_math = math_indicators.any? do |indicator|
      if indicator.is_a?(Regexp)
        message.match?(indicator)
      else
        message.include?(indicator.to_s)
      end
    end
    
    if has_math
      { allowed: true }
    else
      { 
        allowed: false, 
        reason: "This agent specializes in mathematical calculations and equations.",
        suggested_rephrase: "Try: 'Calculate #{message}' or include numbers and mathematical operations."
      }
    end
  end

  # Output guardrail to ensure mathematical context
  def self.output_guardrail(response, context)
    # Ensure mathematical responses are properly formatted
    unless response.include?('📊') || response.include?('=') || response.match?(/\d/)
      enhanced_response = "🧮 Mathematical Result: #{response}"
    else
      enhanced_response = response
    end
    
    { allowed: true, enhanced_response: enhanced_response }
  end

  uses CalculatorTool
end

class KnowledgeCoordinator < Agents::Agent
  name "Knowledge Hub Coordinator"
  instructions <<~PROMPT
    You are a smart coordinator for a comprehensive knowledge hub with guardrails for safe operation.
    
    Route user queries to the appropriate specialists:
    🧮 For calculations, math problems, equations → CalculatorAgent
    📚 For documentation, API guides, platform features → DocumentationAgent  
    🌐 For web search, current news, general information → WebSearchAgent
    
    If a query involves multiple areas, coordinate between agents. Always ensure users get comprehensive answers.
    The system has guardrails to ensure appropriate content and helpful responses.
  PROMPT

  # Coordinator guardrail to route appropriately
  def self.input_guardrail(message, context)
    # Block obviously inappropriate requests
    inappropriate_terms = ['illegal', 'harmful', 'dangerous', 'exploit']
    
    if inappropriate_terms.any? { |term| message.downcase.include?(term) }
      { 
        allowed: false, 
        reason: "Request contains inappropriate content. Please ask for helpful information instead.",
        suggested_rephrase: "Try asking for documentation, calculations, or general information."
      }
    else
      { allowed: true }
    end
  end
end

# Set up handoffs between all agents
KnowledgeCoordinator.class_eval { handoffs DocumentationAgent, WebSearchAgent, CalculatorAgent }
DocumentationAgent.class_eval { handoffs KnowledgeCoordinator, WebSearchAgent, CalculatorAgent }
WebSearchAgent.class_eval { handoffs KnowledgeCoordinator, DocumentationAgent, CalculatorAgent }
CalculatorAgent.class_eval { handoffs KnowledgeCoordinator, DocumentationAgent, WebSearchAgent }

# Interactive Knowledge Hub Interface
class KnowledgeHubInterface
  def initialize
    @context = KnowledgeHubContext.new
    @runner = Agents::Runner.new(initial_agent: KnowledgeCoordinator, context: @context)
    @session_active = true
  end

  def start
    display_welcome
    display_status
    
    while @session_active
      print_prompt
      input = get_user_input.strip
      
      case input.downcase
      when '/help'
        display_help
      when '/status'
        display_detailed_status
      when '/stats'
        display_session_stats
      when '/capabilities'
        display_capabilities
      when '/examples'
        display_examples
      when '/demo'
        run_demo_queries
      when '/clear'
        clear_screen
        display_welcome
      when '/quit', '/exit', 'quit', 'exit'
        @session_active = false
        puts "🎓 Thank you for using the Knowledge Hub! Keep learning! 🚀"
      when ''
        # Skip empty input
      else
        process_query(input)
      end
    end
    
    # Cleanup MCP connections
    cleanup_connections
  end

  private

  def display_welcome
    clear_screen
    puts <<~WELCOME
      🎓 Interactive Knowledge Hub - Ruby Agents SDK
      =============================================
      
      Welcome to your comprehensive AI-powered knowledge assistant!
      
      🤖 Available Specialists:
      • 📚 Documentation Expert - Official docs, APIs, guides
      • 🌐 Web Research Specialist - Current info, news, trends  
      • 🧮 Mathematics Expert - Calculations, equations, analysis
      
      💡 Ask anything and watch AI agents collaborate to find answers!
      
    WELCOME
  end

  def display_status
    puts "🔌 System Status:"
    puts "📚 Documentation: #{@context.mintlify_connected? ? '✅ Connected' : '❌ Offline'}"
    puts "🌐 Web Search: #{@context.websearch_connected? ? '✅ Connected' : '❌ Offline'}"  
    puts "🧮 Calculator: ✅ Ready"
    puts "🤖 OpenAI API: #{ENV['OPENAI_API_KEY'] ? '✅ Ready' : '❌ Not configured'}"
    puts
  end

  def display_help
    puts <<~HELP
      
      📖 Commands & Usage:
      --------------------
      /help        - Show this help message
      /status      - Show detailed system status
      /stats       - Show session statistics
      /capabilities- Show what each agent can do
      /examples    - Show example queries
      /demo        - Run demonstration queries
      /clear       - Clear screen and restart
      /quit        - Exit the knowledge hub
      
      💡 Just type your question naturally! Examples:
      "What's 15 * 24 + 30?"
      "How do I set up API authentication?"
      "What's the latest news about AI?"
      "Search for webhook documentation"
      
    HELP
  end

  def display_detailed_status
    puts <<~STATUS
      
      📊 Detailed System Status:
      --------------------------
      Current Agent: #{@runner.current_agent.class.name.split('::').last}
      Session Queries: #{@context.session_stats[:queries_processed]}
      
      🔌 MCP Connections:
      • Mintlify Documentation: #{@context.mintlify_connected? ? '✅ Healthy' : '❌ Disconnected'}
      • WebSearch Service: #{@context.websearch_connected? ? '✅ Healthy' : '❌ Disconnected'}
      
      🧠 AI Processing:
      • OpenAI API: #{ENV['OPENAI_API_KEY'] ? '✅ Configured' : '❌ Missing API key'}
      • Agent Transitions: #{@context.agent_transitions.length}
      
    STATUS
  end

  def display_session_stats
    stats = @context.session_stats
    puts <<~STATS
      
      📈 Session Statistics:
      ----------------------
      Total Queries: #{stats[:queries_processed]}
      Documentation Searches: #{stats[:docs_searched]}
      Web Searches: #{stats[:web_searches]}
      Calculations: #{stats[:calculations]}
      
      🔄 Recent Agent Activity:
    STATS
    
    if @context.agent_transitions.any?
      @context.agent_transitions.last(3).each do |transition|
        puts "  #{transition[:from]} → #{transition[:to]}"
      end
    else
      puts "  No agent transitions yet"
    end
    puts
  end

  def display_capabilities
    puts <<~CAPABILITIES
      
      🎯 Agent Capabilities:
      ----------------------
      
      📚 Documentation Expert:
      • Search through official documentation
      • Find API references and guides
      • Get specific documentation pages
      • Navigate documentation structure
      
      🌐 Web Research Specialist:
      • Search current web information
      • Find recent news and updates
      • Research general topics
      • Discover trends and developments
      
      🧮 Mathematics Expert:
      • Perform calculations and solve equations
      • Handle complex mathematical expressions
      • Show step-by-step solutions
      • Analyze numerical data
      
      🤖 Smart Coordination:
      • Automatically route queries to best specialist
      • Coordinate multi-agent responses
      • Provide comprehensive answers
      
    CAPABILITIES
  end

  def display_examples
    puts <<~EXAMPLES
      
      💡 Example Queries:
      -------------------
      
      🧮 Math & Calculations:
      • "What's 15% of 240?"
      • "Calculate (125 * 8) + (300 / 6)"
      • "What's the square root of 144?"
      
      📚 Documentation:
      • "How do I authenticate API requests?"
      • "Show me webhook documentation"
      • "What integrations are available?"
      
      🌐 Web Research:
      • "What's the latest news about Ruby?"
      • "Search for React best practices"
      • "Find information about AI trends"
      
      🔄 Multi-Agent:
      • "Calculate ROI for API integration costs"
      • "Find documentation and recent news about webhooks"
      • "What's 2+2 and also search for math tutorials"
      
    EXAMPLES
  end

  def run_demo_queries
    puts "\n🎬 Running Demo Queries..."
    puts "=" * 40
    
    demo_queries = [
      "Calculate 15 * 24 + 30",
      "Search for API authentication documentation", 
      "What's the latest news about Ruby programming?",
      "Find webhook documentation and calculate 25% of 200"
    ]
    
    demo_queries.each_with_index do |query, i|
      puts "\n#{i+1}. Demo Query: #{query}"
      puts "-" * 30
      process_query(query)
      sleep(1) # Brief pause between demos
    end
    
    puts "\n✅ Demo completed!"
  end

  def print_prompt
    print "\n🎓 Ask anything: "
  end

  def get_user_input
    input = gets
    return 'quit' if input.nil? # Handle EOF gracefully
    input.chomp
  end

  def process_query(query)
    unless ENV['OPENAI_API_KEY']
      puts "❌ OpenAI API key required. Set OPENAI_API_KEY environment variable."
      return
    end

    puts "\n🔍 Processing your query..."
    
    start_time = Time.now
    
    begin
      response = @runner.process(query)
      duration = ((Time.now - start_time) * 1000).round
      
      puts "\n" + "="*60
      puts "🤖 Response:"
      puts response
      puts "="*60
      puts "⏱️  Response time: #{duration}ms"
      
      # Show agent workflow if there were transitions
      if @context.agent_transitions.any?
        recent = @context.agent_transitions.last
        if recent[:from] != recent[:to]
          puts "🔄 Agent: #{recent[:from]} → #{recent[:to]}"
        end
      end
      
      # Update session stats
      @context.increment_stat(:queries_processed)
      
    rescue => e
      puts "❌ Error processing query: #{e.message}"
      puts "Error backtrace:" if ENV['DEBUG']
      puts e.backtrace.first(10).join("\n") if ENV['DEBUG']
      puts "💡 Try rephrasing your question or use /help for guidance"
    end
  end

  def clear_screen
    system('clear') || system('cls')
  end

  def cleanup_connections
    @context.mcp_clients.each do |name, client|
      client&.disconnect rescue nil
    end
  end
end

# Main execution
if ENV['OPENAI_API_KEY']
  puts "🚀 Starting Interactive Knowledge Hub..."
  
  hub = KnowledgeHubInterface.new
  hub.start
  
else
  puts <<~INFO
    🎓 Interactive Knowledge Hub - Ruby Agents SDK
    ==============================================
    
    This example demonstrates a comprehensive AI knowledge assistant with:
    
    🔧 Features:
    • 📚 Documentation search via Mintlify MCP
    • 🌐 Web search via WebSearch MCP  
    • 🧮 Mathematical calculations
    • 🤖 Multi-agent coordination
    • 💬 Interactive chat interface
    
    🚀 To start:
    export OPENAI_API_KEY=your-api-key-here
    ruby examples/interactive_knowledge_hub.rb
    
    This showcases the full power of Ruby Agents SDK with:
    • Real MCP protocol integration (stdio)
    • Multiple specialized AI agents
    • Interactive user experience
    • Production-ready error handling
    • Session management and statistics
    
  INFO
end