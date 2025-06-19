<div align="center">
<br>
<br>
<p>
  <img src="./.github/ruby-agent.png" width="200px"/>
  <h1>Ruby Agents</h1>
</p>
<br>
<br>
</div>

A Ruby SDK for building multi-agent AI workflows with seamless handoffs, inspired by OpenAI's Agents SDK but built specifically for Ruby developers.

## ✨ Features

- **🤖 Multi-Agent Orchestration**: Create specialized AI agents that work together
- **🔄 Seamless Handoffs**: Transparent agent-to-agent transfers (users never know!)
- **🛠️ Tool Integration**: Agents can use custom tools and functions
- **💾 Shared Context**: State management across agent interactions
- **🚀 Simple API**: One method call handles everything including handoffs
- **🔌 Provider Agnostic**: Works with OpenAI, Anthropic, and other LLM providers

## 🚀 Quick Start

### Installation

Add to your Gemfile:

```ruby
gem 'ruby-agents'
```

### Basic Usage

```ruby
require 'agents'

# Configure with your API key
Agents.configure do |config|
  config.openai_api_key = ENV['OPENAI_API_KEY']
  config.default_model = 'gpt-4o'
end

# Create a simple agent
class WeatherAgent < Agents::Agent
  name "Weather Assistant"
  instructions "Help users get weather information"

  uses WeatherTool
end

# Use the agent
agent = WeatherAgent.new
response = agent.call("What's the weather like today?")
puts response.content
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

## 🔧 Configuration

```ruby
Agents.configure do |config|
  # Provider API keys
  config.openai_api_key = ENV['OPENAI_API_KEY']
  config.anthropic_api_key = ENV['ANTHROPIC_API_KEY']
  config.gemini_api_key = ENV['GEMINI_API_KEY']

  # Defaults
  config.default_provider = :openai
  config.default_model = 'gpt-4o'

  # Performance
  config.request_timeout = 120
  config.max_turns = 10

  # Debugging
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

## 🙏 Acknowledgments

- Inspired by [OpenAI's Agents SDK](https://github.com/openai/agents)
- Built on top of [RubyLLM](https://rubyllm.com) for LLM integration
- Thanks to the Ruby community for continuous inspiration

---

**Built with ❤️ by the Chatwoot Team**
