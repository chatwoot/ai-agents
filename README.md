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
end

# Create a simple agent
agent = Agents::Agent.new(
  name: "Weather Assistant",
  instructions: "Help users get weather information",
  tools: [WeatherTool.new]
)

# Use the agent with the Runner
result = Agents::Runner.run(agent, "What's the weather like today?")
puts result.output
```

### Multi-Agent Workflows with Handoffs

The real power comes from multi-agent workflows with automatic handoffs:

```ruby
# Create specialized agents
triage = Agents::Agent.new(
  name: "Triage Agent",
  instructions: "Route customers to the right specialist"
)

faq = Agents::Agent.new(
  name: "FAQ Agent",
  instructions: "Answer frequently asked questions",
  tools: [FaqLookupTool.new]
)

support = Agents::Agent.new(
  name: "Support Agent",
  instructions: "Handle technical issues",
  tools: [TicketTool.new]
)

# Wire up handoff relationships - clean and simple!
triage.register_handoffs(faq, support)
faq.register_handoffs(triage)     # Can route back to triage
support.register_handoffs(triage)  # Hub-and-spoke pattern

# Run a conversation with automatic handoffs
result = Agents::Runner.run(triage, "How many seats are on the plane?")
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

Agents can be created in two ways:

#### Instance-based (Recommended for dynamic agents)

```ruby
# Create agents as instances
agent = Agents::Agent.new(
  name: "Customer Service",
  instructions: "You are a helpful customer service agent.",
  model: "gpt-4o",
  tools: [EmailTool.new, TicketTool.new]
)

# Register handoffs after creation
agent.register_handoffs(technical_support, billing)
```

#### Class-based (Coming soon)

```ruby
class CustomerServiceAgent < Agents::Agent
  name "Customer Service"
  instructions <<~PROMPT
    You are a helpful customer service agent.
    Always be polite and professional.
  PROMPT

  model "gpt-4o"
  uses EmailTool, TicketTool
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

### Handoff Patterns

#### Hub-and-Spoke Pattern (Recommended)

```ruby
# Central triage agent routes to specialists
triage = Agents::Agent.new(name: "Triage")
billing = Agents::Agent.new(name: "Billing")
support = Agents::Agent.new(name: "Support")

# Triage can route to any specialist
triage.register_handoffs(billing, support)

# Specialists only route back to triage
billing.register_handoffs(triage)
support.register_handoffs(triage)
```

#### Circular Handoffs

```ruby
# Agents can hand off to each other
sales = Agents::Agent.new(name: "Sales")
customer_info = Agents::Agent.new(name: "Customer Info")

# Both agents can transfer to each other
sales.register_handoffs(customer_info)
customer_info.register_handoffs(sales)
```

### Context Management

```ruby
# Context is automatically managed by the Runner
context = {}
result = Agents::Runner.run(agent, "Hello", context: context)

# Access conversation history and agent state
puts context[:conversation_history]
puts context[:current_agent].name
```

## 📋 Examples

### ISP Customer Support

See the complete ISP support example in `examples/isp-support/`:

```ruby
# Run the interactive demo
ruby examples/isp-support/interactive.rb
```

This showcases:
- **Triage Agent**: Routes customers to appropriate specialists
- **Customer Info Agent**: Handles account info and billing inquiries
- **Sales Agent**: Manages new connections and upgrades
- **Support Agent**: Provides technical troubleshooting
- **Hub-and-Spoke Handoffs**: Clean architecture pattern

### Airline Customer Service

See the airline booking example in `examples/booking/`:

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
