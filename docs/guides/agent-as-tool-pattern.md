---
layout: default
title: Agent-as-Tool Pattern
parent: Guides
nav_order: 4
---

# Agent-as-Tool Pattern Guide

The Agent-as-Tool pattern enables sophisticated **multi-agent collaboration** where specialized agents work behind the scenes to help each other, without the user ever knowing multiple agents are involved.

## When to Use This Pattern

Use the Agent-as-Tool pattern when you need:

- **Specialized Processing**: Different agents excel at different tasks
- **Modular Architecture**: Clean separation of concerns between agents
- **Behind-the-Scenes Coordination**: Agents collaborate without user awareness
- **Complex Workflows**: Multi-step processes requiring different expertise

## Core Concepts

### Traditional Handoffs vs Agent-as-Tool

**Handoffs**: "Let me transfer you to our billing specialist"
- User-visible conversation transfer
- Full context and conversation history
- Agent takes over the conversation

**Agent-as-Tool**: "Let me check that for you" (internally uses billing agent)
- Invisible to the user
- Limited context (state only)
- Returns control to original agent

## Implementation Guide

### Step 1: Design Your Agents

Create specialized agents focused on specific domains:

```ruby
# Agent specialized in conversation analysis
conversation_agent = Agents::Agent.new(
  name: "ConversationAnalyzer",
  instructions: <<~PROMPT
    You are a conversation analysis specialist. Extract key information from conversation history:
    - Customer sentiment
    - Order numbers or IDs mentioned
    - Product issues described
    - Urgency level

    Return structured data in this format:
    - Sentiment: [positive/negative/neutral]
    - Order ID: [if mentioned]
    - Issue Type: [billing/technical/shipping/other]
    - Urgency: [low/medium/high]
  PROMPT
)

# Agent specialized in Shopify operations
shopify_agent = Agents::Agent.new(
  name: "ShopifyAgent",
  instructions: <<~PROMPT
    You are a Shopify operations specialist. Use the provided tools to:
    - Look up order details
    - Process refunds
    - Update order status
    - Handle customer account issues

    Always confirm the action you're taking and provide order details.
  PROMPT,
  tools: [shopify_lookup_tool, shopify_refund_tool, shopify_update_tool]
)
```

### Step 2: Create the Orchestrator

Build a main agent that coordinates the specialists:

```ruby
# Main agent that orchestrates the specialists
support_copilot = Agents::Agent.new(
  name: "SupportCopilot",
  instructions: <<~PROMPT
    You are an AI assistant helping customer support agents. You have access to specialist agents:

    1. Use `analyze_conversation` to understand customer issues and sentiment
    2. Use `shopify_action` to perform order operations when needed
    3. Always provide helpful, accurate information to support the agent

    Work efficiently and provide clear, actionable recommendations.
  PROMPT,
  tools: [
    # Convert specialist agents to tools
    conversation_agent.as_tool(
      name: "analyze_conversation",
      description: "Analyze conversation history for sentiment, issues, and key details"
    ),
    shopify_agent.as_tool(
      name: "shopify_action",
      description: "Perform Shopify operations like lookups, refunds, or updates"
    )
  ]
)
```

### Step 3: Set Up the Runner

Use the orchestrator in your application:

```ruby
# Create runner with the main orchestrator
runner = Agents::AgentRunner.new(support_copilot)

# The user only interacts with the main agent
result = runner.run("Can you help me process a refund for order #12345?")

# Behind the scenes:
# 1. Main agent receives the request
# 2. Calls analyze_conversation tool to understand the request
# 3. Calls shopify_action tool to process the refund
# 4. Returns consolidated response to user
```

## Real-World Example

Let's build a complete customer support copilot:

### Domain-Specific Tools

```ruby
# Tool for looking up customer conversations
class SearchConversationsTools < Agents::Tool
  param :query, type: "string", desc: "Search query for conversations"
  param :customer_id, type: "string", desc: "Customer ID to filter by", required: false

  def perform(tool_context, query:, customer_id: nil)
    # Implementation to search conversation database
    conversations = ConversationService.search(query, customer_id: customer_id)
    conversations.map(&:to_json)
  end
end

# Tool for Shopify operations
class ShopifyOperationTool < Agents::Tool
  param :action, type: "string", desc: "Action to perform (lookup, refund, update)"
  param :order_id, type: "string", desc: "Shopify order ID"
  param :amount, type: "number", desc: "Refund amount", required: false

  def perform(tool_context, action:, order_id:, amount: nil)
    case action
    when "lookup"
      ShopifyService.get_order(order_id)
    when "refund"
      ShopifyService.process_refund(order_id, amount)
    when "update"
      ShopifyService.update_order(order_id)
    end
  end
end
```

### Specialized Agents

```ruby
# Research agent for gathering information
research_agent = Agents::Agent.new(
  name: "ResearchAgent",
  instructions: <<~PROMPT
    You research customer issues by analyzing conversation history and gathering relevant context.

    Steps to follow:
    1. Search for relevant conversations using the customer's information
    2. Identify patterns or recurring issues
    3. Extract key details like order numbers, product issues, or account problems
    4. Summarize findings clearly
  PROMPT,
  tools: [SearchConversationsTools.new]
)

# Integration agent for system operations
integration_agent = Agents::Agent.new(
  name: "IntegrationAgent",
  instructions: <<~PROMPT
    You handle system integrations and operations like Shopify, billing, or CRM updates.

    Capabilities:
    - Look up order details in Shopify
    - Process refunds and exchanges
    - Update customer information
    - Handle billing inquiries

    Always confirm actions before executing them.
  PROMPT,
  tools: [ShopifyOperationTool.new]
)

# Analysis agent for processing information
analysis_agent = Agents::Agent.new(
  name: "AnalysisAgent",
  instructions: <<~PROMPT
    You analyze customer data and conversations to provide insights and recommendations.

    Focus on:
    - Customer sentiment and satisfaction
    - Issue categorization and priority
    - Recommended next steps
    - Potential escalation needs
  PROMPT
)
```

### Main Orchestrator

```ruby
# Main copilot that coordinates everything
copilot = Agents::Agent.new(
  name: "SupportCopilot",
  instructions: <<~PROMPT
    You are an AI copilot helping customer support agents be more effective.

    Your specialist capabilities:
    - `research_customer`: Research customer history and context
    - `analyze_situation`: Analyze customer issues and provide insights
    - `handle_integration`: Perform system operations like refunds or lookups

    Workflow:
    1. Understand what the support agent needs help with
    2. Use specialist agents to gather information and perform actions
    3. Provide clear, actionable recommendations
    4. Always be helpful and accurate
  PROMPT,
  tools: [
    research_agent.as_tool(
      name: "research_customer",
      description: "Research customer conversation history and context"
    ),
    analysis_agent.as_tool(
      name: "analyze_situation",
      description: "Analyze customer issues and provide insights"
    ),
    integration_agent.as_tool(
      name: "handle_integration",
      description: "Perform system operations like Shopify lookups or refunds"
    )
  ]
)
```

## Advanced Patterns

### Output Transformation

Transform agent outputs for specific use cases:

```ruby
# Agent that returns JSON data
data_agent = Agents::Agent.new(
  name: "DataAgent",
  instructions: "Return customer data in JSON format"
)

# Transform JSON to summary
summary_tool = data_agent.as_tool(
  name: "get_summary",
  description: "Get customer summary",
  output_extractor: ->(result) {
    data = JSON.parse(result.output)
    "Customer #{data['name']} has #{data['orders']} orders, last contact: #{data['last_contact']}"
  }
)
```

### Conditional Agent Selection

Use different agents based on context:

```ruby
class SmartCopilot < Agents::Agent
  def initialize
    @billing_agent = create_billing_agent
    @technical_agent = create_technical_agent
    @general_agent = create_general_agent

    super(
      name: "SmartCopilot",
      instructions: "Route requests to appropriate specialists",
      tools: [
        @billing_agent.as_tool(name: "handle_billing"),
        @technical_agent.as_tool(name: "handle_technical"),
        @general_agent.as_tool(name: "handle_general")
      ]
    )
  end
end
```

### State Sharing Between Agents

Share important state across agent interactions:

```ruby
# Set up shared state
runner = Agents::AgentRunner.new(copilot)
context = {
  state: {
    customer_id: "12345",
    session_type: "billing_inquiry",
    priority: "high"
  }
}

# All agent tools will receive this state
result = runner.run("Help me with this billing issue", context: context)
```

## Best Practices

### 1. Design Clear Boundaries

Each agent should have a well-defined responsibility:

```ruby
# Good: Focused responsibility
order_agent = Agent.new(
  name: "OrderAgent",
  instructions: "Handle order lookups, modifications, and cancellations"
)

# Avoid: Too broad
everything_agent = Agent.new(
  name: "EverythingAgent",
  instructions: "Handle orders, billing, shipping, returns, and customer service"
)
```

### 2. Use Descriptive Tool Names

Make tool calls clear and intuitive:

```ruby
# Good: Clear purpose
agent.as_tool(
  name: "analyze_customer_sentiment",
  description: "Analyze customer conversation for sentiment and urgency"
)

# Avoid: Vague naming
agent.as_tool(name: "process", description: "Do stuff")
```

### 3. Handle Errors Gracefully

Agent tools can fail, so handle errors appropriately:

```ruby
copilot = Agent.new(
  name: "Copilot",
  instructions: <<~PROMPT
    When using specialist agents:

    1. If a tool returns an error, try alternative approaches
    2. Always provide helpful responses even if some tools fail
    3. Let the user know if critical information is unavailable
  PROMPT
)
```

### 4. Optimize Performance

Consider the performance impact of multiple agent calls:

```ruby
# Good: Batch related operations
instructions = <<~PROMPT
  When handling customer requests:
  1. Use research_customer to gather all necessary context first
  2. Then use analyze_situation to process everything at once
  3. Finally use handle_integration for any required actions
PROMPT

# Avoid: Excessive back-and-forth
# Multiple small agent calls that could be combined
```

### 5. Monitor and Debug

Use logging to understand agent interactions:

```ruby
Agents.configure do |config|
  config.debug = true  # Enable detailed logging
end

# Review logs to see:
# - Which agents are called
# - What context is shared
# - How long operations take
# - Error patterns
```

## Testing Agent-as-Tool Patterns

Test your multi-agent setup thoroughly:

```ruby
RSpec.describe "Support Copilot" do
  let(:copilot) { create_support_copilot }
  let(:runner) { Agents::AgentRunner.new(copilot) }

  it "handles billing inquiries with order lookup" do
    # Mock the underlying agent tools
    allow_any_instance_of(ResearchAgent).to receive(:execute)
      .and_return("Customer has order #12345")

    result = runner.run("Can you help me with order #12345?")

    expect(result.output).to include("order #12345")
    expect(result.context[:state]).to include(:customer_researched)
  end
end
```

## Common Pitfalls

### 1. Over-Engineering

Don't create complex agent hierarchies when simple tools would work:

```ruby
# Sometimes a simple tool is better than an agent-as-tool
class SimpleCalculatorTool < Agents::Tool
  param :expression, type: "string"

  def perform(tool_context, expression:)
    eval(expression) # (with proper safety checks)
  end
end

# Instead of:
calculator_agent = Agent.new(
  name: "Calculator",
  instructions: "Evaluate mathematical expressions"
)
```

### 2. Context Pollution

Remember that agent tools only receive state, not full context:

```ruby
# This won't work - conversation history isn't shared
analyze_agent = Agent.new(
  instructions: "Look at the conversation history and analyze sentiment"
)

# This will work - pass relevant data through state
runner = AgentRunner.new(main_agent)
result = runner.run("Analyze this", context: {
  state: {
    conversation_data: "Customer seems frustrated about delivery delay"
  }
})
```

### 3. Infinite Loops

Avoid agents that could call each other indefinitely:

```ruby
# Dangerous: Could create infinite loops
agent_a = Agent.new(tools: [agent_b.as_tool])
agent_b = Agent.new(tools: [agent_a.as_tool])

# Safe: Clear hierarchy and limited turns
orchestrator = Agent.new(tools: [specialist_a.as_tool, specialist_b.as_tool])
```
