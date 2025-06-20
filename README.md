# Ruby Agents SDK

[![Gem Version](https://badge.fury.io/rb/ruby-agents.svg)](https://badge.fury.io/rb/ruby-agents)
[![Ruby](https://github.com/ruby-agents/ruby-agents/actions/workflows/main.yml/badge.svg)](https://github.com/ruby-agents/ruby-agents/actions/workflows/main.yml)

A production-ready Ruby SDK for building sophisticated multi-agent AI workflows with intelligent handoffs, tool execution, and comprehensive observability.

## Features

🤖 **Multi-Agent Orchestration** - Create specialized agents that seamlessly hand off conversations
🔧 **Tool Integration** - Define custom tools with automatic LLM function calling
🔄 **Intelligent Handoffs** - Automatic agent routing based on conversation context
🛡️ **Built-in Guardrails** - Input/output validation and content filtering
📊 **Comprehensive Tracing** - Built-in observability for debugging and monitoring
🔌 **Provider Agnostic** - Support for OpenAI, Anthropic, and custom LLM providers
⚡ **Production Ready** - Robust error handling, retry logic, and performance optimization

## 🚀 Quick Start

### Installation

Add to your Gemfile:

```ruby
gem 'ruby-agents'
```

### Basic Usage

```ruby
require 'agents'

# Configure with your API key and providers
Agents.configure do |config|
  config.openai_api_key = ENV['OPENAI_API_KEY']
  config.anthropic_api_key = ENV['ANTHROPIC_API_KEY']
  config.default_provider = :openai
  config.default_model = 'gpt-4.1-mini'
end

# Create a simple agent
class WeatherAgent < Agents::Agent
  name "Weather Assistant"
  instructions "Help users get weather information"
  provider :openai
  model "gpt-4.1-mini"

  uses WeatherTool
end

# Use the agent
agent = WeatherAgent.new
response = agent.call("What's the weather like today?")
puts response.content
```

### Enhanced Agent with All Features

```ruby
class EnhancedWeatherAgent < Agents::Agent
  name "Enhanced Weather Assistant"
  instructions "Provide weather information with safety checks"
  provider :openai
  model "gpt-4.1-mini"
  
  # MCP server integration
  mcp_servers :filesystem, :weather_api
  
  # Input guardrails
  input_guardrail name: "weather_topics_only",
                  allowed_topics: ["weather", "forecast", "temperature"],
                  check_prompt_injection: true,
                  max_length: 500
  
  input_guardrail name: "no_pii" do |message, context|
    # Custom validation block
    !message.match?(/\b\d{3}-\d{2}-\d{4}\b/) # No SSN
  end
  
  # Output guardrails
  output_guardrail name: "safe_weather_responses",
                   check_harmful_content: true,
                   require_sources: true,
                   max_length: 1000
  
  # Traditional tools
  uses WeatherTool, LocationTool
  
  # Handoff capabilities
  handoffs SupportAgent, SpecialistAgent
end
```

### Multi-Agent Workflows with Runner

The real power comes from multi-agent workflows with automatic handoffs:

```ruby
# Define specialized agents
class TriageAgent < Agents::Agent
  name "Triage Agent"
  instructions "Route customers to the right specialist"
  handoffs FaqAgent, SupportAgent
end

class FaqAgent < Agents::Agent
  name "FAQ Agent"
  instructions "Answer frequently asked questions"
  uses FaqLookupTool
end

# Create a runner for seamless multi-agent conversations
context = Agents::Context.new
runner = Agents::Runner.new(
  initial_agent: TriageAgent,
  context: context
)

# One call handles everything - handoffs are invisible to users
response = runner.process("How many seats are on the plane?")
# User gets direct answer from FAQ agent without knowing about the handoff!
```

## 🏗️ Architecture

### Core Components

- **Agent**: Individual AI agents with specific roles and capabilities
- **Runner**: Orchestrates multi-agent conversations with automatic handoffs
- **Context**: Shared state management across agents
- **Tools**: Custom functions that agents can use
- **Handoffs**: Seamless transfers between specialized agents

### Agent Definition

```ruby
class CustomerServiceAgent < Agents::Agent
  name "Customer Service"
  instructions <<~PROMPT
    You are a helpful customer service agent.
    Always be polite and professional.
  PROMPT

  provider :openai
  model "gpt-4o"

  uses EmailTool, TicketTool
  handoffs TechnicalSupportAgent, BillingAgent
end
```

### Custom Tools

```ruby
class EmailTool < Agents::Tool
  description "Send emails to customers"
  param :to, String, "Email address"
  param :subject, String, "Email subject"
  param :body, String, "Email body"

  def perform(to:, subject:, body:, context:)
    # Send email logic here
    "Email sent to #{to}"
  end
end
```

### Context Management

```ruby
class OrderContext < Agents::Context
  attr_accessor :customer_id, :order_number, :status

  def initialize
    super
    @customer_id = nil
    @order_number = nil
    @status = "pending"
  end
end
```

## 📋 Example: Airline Customer Service

See the complete airline booking example in `examples/booking/`:

```ruby
# Run the interactive demo
ruby examples/booking/interactive.rb
```

This showcases:
- **Triage Agent**: Routes questions to specialists
- **FAQ Agent**: Answers questions about policies, seats, baggage
- **Seat Booking Agent**: Handles seat changes and updates
- **Seamless Handoffs**: Users never repeat their questions

### Sample Conversation

```
You: How many seats are on the plane?

Agent: The plane has a total of 120 seats, which includes 22 business
class seats and 98 economy seats. Exit rows are located at rows 4 and
16, and rows 5-8 are designated as Economy Plus, offering extra legroom.
```

Behind the scenes:
1. Triage Agent receives question
2. Automatically transfers to FAQ Agent
3. FAQ Agent processes original question and responds
4. User sees seamless experience!

## 🔌 MCP Server Integration

### Setup MCP Servers

```bash
# Install MCP servers
npm install -g @modelcontextprotocol/server-filesystem
npm install -g @modelcontextprotocol/server-sqlite

# Configure with CLI
./bin/mcp sync filesystem npx @modelcontextprotocol/server-filesystem ./docs
./bin/mcp sync database npx @modelcontextprotocol/server-sqlite ./data.db
./bin/mcp list
```

### Use MCP Tools in Agents

```ruby
# MCP tools are automatically discovered and registered
class DataAgent < Agents::Agent
  name "Data Analysis Agent"
  instructions "Analyze data using filesystem and database tools"
  
  # These MCP servers provide tools like:
  # - read_file, write_file, list_directory (filesystem)
  # - execute_query, describe_table (database)
  mcp_servers :filesystem, :database
end

agent = DataAgent.new
response = agent.call("What files are in the /reports directory?")
# Agent automatically uses MCP filesystem tools
```

### Mintlify Documentation Integration

```ruby
# Configure Mintlify MCP server
./bin/mcp sync mintlify npx mint-mcp add acme-d0cb791b

# Create documentation assistant
class MintlifyAgent < Agents::Agent
  name "Documentation Expert"
  instructions "Help users with Mintlify documentation and setup"
  
  # Automatically discovers Mintlify documentation tools
  mcp_servers :mintlify
  
  # Safety for documentation queries only
  input_guardrail name: "docs_only",
                  allowed_topics: ["documentation", "setup", "api"]
end

agent = MintlifyAgent.new
response = agent.call("How do I set up authentication?")
# Agent uses real Mintlify MCP tools for up-to-date documentation
```

### Custom MCP Configuration

```ruby
Agents.configure_mcp({
  'servers' => {
    'weather_service' => {
      'type' => 'sse',
      'url' => 'https://weather-mcp.example.com',
      'auth_token' => ENV['WEATHER_API_TOKEN']
    },
    'local_tools' => {
      'type' => 'stdio', 
      'command' => 'python',
      'args' => ['./custom_mcp_server.py'],
      'working_directory' => './tools'
    }
  }
})
```

## 📊 Tracing & Monitoring

### Configure Tracing

```ruby
Agents.configure_tracing({
  enabled: true,
  output_file: 'traces/agents.jsonl',
  console_output: true,
  buffer_size: 100
})

# Start a trace
trace = Agents.start_trace("user_workflow", { user_id: "123" })

# Agent calls are automatically traced
agent = WeatherAgent.new
response = agent.call("What's the weather?")

# Trace events include:
# - agent.start, agent.complete
# - guardrails.input.start, guardrails.input.complete  
# - llm.request.start, llm.request.complete
# - tool.call.start, tool.call.complete
# - mcp.connect, mcp.tool_call
# - handoff.transfer
```

### View Traces

```bash
# Analyze traces with built-in tools
./bin/agents traces show --recent
./bin/agents traces analyze --performance
./bin/agents health
```

## 🔧 Configuration

```ruby
Agents.configure do |config|
  # Provider API keys
  config.openai_api_key = ENV['OPENAI_API_KEY']
  config.anthropic_api_key = ENV['ANTHROPIC_API_KEY']
  config.gemini_api_key = ENV['GEMINI_API_KEY']
  config.deepseek_api_key = ENV['DEEPSEEK_API_KEY']

  # Provider settings
  config.default_provider = :openai
  config.default_model = 'gpt-4.1-mini'
  config.provider_fallback_chain = [:openai, :anthropic, :gemini]

  # Performance
  config.request_timeout = 120
  config.max_turns = 10

  # Debugging and monitoring
  config.debug = true
end
```

## 🤝 Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Run tests (`rake test`)
4. Run linter (`rake rubocop`)
5. Commit your changes (`git commit -am 'Add amazing feature'`)
6. Push to the branch (`git push origin feature/amazing-feature`)
7. Open a Pull Request

## 📝 License

This project is licensed under the MIT License - see the LICENSE file for details.


**Legend:** ✅ Implemented | 🚧 In Progress | ❌ Not Available

## 🚀 Getting Started

1. **Install the gem**
   ```bash
   gem install ruby-agents
   ```

2. **Set up your environment**
   ```bash
   export OPENAI_API_KEY="your-api-key"
   export ANTHROPIC_API_KEY="your-anthropic-key"
   ```

3. **Install MCP servers (optional)**
   ```bash
   npm install -g @modelcontextprotocol/server-filesystem
   ./bin/mcp sync filesystem npx @modelcontextprotocol/server-filesystem ./docs
   ```

4. **Run the examples**
   ```bash
   ruby examples/complete_example.rb
   ruby examples/mintlify_mcp_example.rb
   ruby examples/ultimate_live_test.rb
   ```

5. **Start building!**
   ```ruby
   require 'agents'
   
   class MyAgent < Agents::Agent
     name "My First Agent"
     instructions "You are a helpful assistant"
     
     mcp_servers :filesystem  # Use MCP tools
     
     input_guardrail name: "safety" do |input, context|
       # Custom safety check
       !input.downcase.include?("dangerous")
     end
   end
   ```

## 🙏 Acknowledgments

- Inspired by [OpenAI's Agents SDK](https://github.com/openai/openai-agents-python)
- Built with the [Model Context Protocol](https://modelcontextprotocol.io)
- Integrates with [RubyLLM](https://rubyllm.com) ecosystem
- Thanks to the Ruby community for continuous inspiration

---

**Built with ❤️ by the Chatwoot Team**

