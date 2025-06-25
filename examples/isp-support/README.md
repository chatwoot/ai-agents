# ISP Customer Support Multi-Agent System

This example demonstrates a complete ISP (Internet Service Provider) customer support system using the Ruby Agents SDK. It showcases how multiple specialized agents can work together to handle different types of customer inquiries through intelligent triage and handoffs.

## System Overview

The ISP support system consists of four specialized agents that collaborate to provide comprehensive customer service:

```
Customer Request
       ↓
   Triage Agent ←─────────────────────┐
       ↓                              │
   ┌───────────────┬──────────────────┼─────────────────┐
   ↓               ↓                  ↓                 ↓
Customer Info ←→ Sales Agent ←→ Support Agent    Escalation
   Agent                                           (Human)
       ↑               ↑                 ↑            ↑
       └───────────────┼─────────────────┼────────────┘
                       └─────────────────┘
```

### Agent Responsibilities

#### 🎯 **Triage Agent**
- **Role**: First point of contact, intelligent request routing
- **Capabilities**:
  - Analyzes customer requests to determine intent
  - Routes to appropriate specialist agent
  - Handles general greetings and initial information gathering
- **Handoffs**: Customer Info, Sales, Support agents (and receives handoffs back for re-routing)
- **Example Routing**:
  - "What's my current plan?" → Customer Info Agent
  - "I want to upgrade" → Sales Agent
  - "Internet is down" → Support Agent

#### 👤 **Customer Info Agent**
- **Role**: Account information and billing inquiries
- **Tools**:
  - `CrmLookupTool`: Access customer account details by ID
  - `HandoffTool`: Route to other agents when needed
- **Capabilities**:
  - Retrieve current service plans and pricing
  - Check account status and billing history
  - Verify customer identity
  - Answer account-related questions
- **Handoffs**: Can route to Sales (for upgrades) or Support (for technical account issues)
- **Sample Data**: Manages dummy customer records with plans, billing info, and service history

#### 💰 **Sales Agent**
- **Role**: New customer acquisition and service upgrades
- **Tools**:
  - `CreateLeadTool`: Generate sales leads in CRM
  - `CreateCheckoutTool`: Generate payment links for new services
  - `HandoffTool`: Route to other agents when appropriate
- **Capabilities**:
  - Qualify leads and gather required information
  - Present available service plans and pricing
  - Create checkout sessions for new subscriptions
  - Handle upgrade requests from existing customers
- **Handoffs**: Can route to Customer Info (for account details) or Triage (for non-sales requests)
- **Lead Requirements**: Name, email, phone, address, desired plan

#### 🔧 **Support Agent**
- **Role**: Technical support and troubleshooting
- **Tools**:
  - `SearchDocsTool`: Search knowledge base for solutions
  - `EscalateToHumanTool`: Hand off complex issues to human agents
  - `HandoffTool`: Route to other agents when needed
- **Capabilities**:
  - Provide step-by-step troubleshooting guidance
  - Search knowledge base for known issues and solutions
  - Escalate complex technical problems to human support
  - Handle service outage inquiries
- **Handoffs**: Can route to Customer Info (for account verification) or escalate to human agents

## Key Features Demonstrated

### 🔄 **Intelligent Agent Handoffs**
- Context-aware routing based on customer intent
- Seamless information transfer between agents
- Proper escalation paths for complex issues

### 🧰 **Specialized Tool Usage**
- Domain-specific tools for each agent type
- Thread-safe tool execution with shared context
- Integration with dummy external systems (CRM, docs, checkout)

### 📊 **Context Management**
- Customer information persistence across handoffs
- Conversation history maintenance
- Shared state for multi-turn interactions

### 🛡️ **Thread Safety**
- Concurrent request handling
- Immutable agent design
- Context isolation between requests

## Example Interactions

### Account Information Query
```
User: "What plan am I currently on?"
Triage → Customer Info Agent
Customer Info Agent: "I can help you with that. What's your account ID?"
User: "CUST001"
Customer Info Agent: [Uses CrmLookupTool] "You're on our Premium Fiber plan (1GB/500MB) for $79.99/month."
```

### Sales Inquiry
```
User: "I want to upgrade to a faster plan"
Triage → Sales Agent
Sales Agent: "Great! I can help you find a better plan. What's your current speed?"
User: "100MB, but I need faster upload for work"
Sales Agent: [Presents options, creates checkout link]
```

### Technical Support
```
User: "My internet keeps disconnecting"
Triage → Support Agent
Support Agent: [Uses SearchDocsTool] "Let's try some troubleshooting steps..."
[If unresolved] → [Uses EscalateToHumanTool]
```

## Implementation Architecture

### Agent Design Patterns
- **Immutable Agents**: Each agent is frozen after creation for thread safety
- **Tool Composition**: Agents are configured with specific tool sets for their domain
- **Dynamic Instructions**: Context-aware prompting based on customer information

### Tool Integration
- **Base Tool Extension**: All tools extend `Agents::Tool` with context injection
- **Thread-Safe Execution**: Context passed through parameters, not instance variables
- **Error Handling**: Graceful degradation when external systems are unavailable

### Context Flow
```ruby
RunContext (shared state)
    ↓
ToolContext (tool-specific wrapper)
    ↓
Tool.perform(tool_context, **params)
```

## Running the Example

### Prerequisites
```bash
# Ensure you have the Ruby Agents SDK configured
bundle install

# Set up your LLM provider (OpenAI recommended)
export OPENAI_API_KEY="your-api-key"
```

### Interactive Demo
```bash
# Run the interactive customer support simulation
ruby examples/isp-support/interactive.rb

# Example session:
# > Customer: "Hi, I'm having trouble with my internet"
# > System: Routing to Support Agent...
# > Support Agent: "I can help you troubleshoot..."
```

### Automated Testing
```bash
# Run predefined scenarios to test all agent interactions
ruby examples/isp-support/test_scenarios.rb
```

## File Structure

```
examples/isp-support/
├── README.md                 # This documentation
├── interactive.rb            # Interactive CLI demo
├── test_scenarios.rb         # Automated test scenarios
├── agents/
│   ├── triage_agent.rb      # Main routing agent
│   ├── customer_info_agent.rb # Account information specialist
│   ├── sales_agent.rb       # Sales and upgrade specialist
│   └── support_agent.rb     # Technical support specialist
├── tools/
│   ├── crm_lookup_tool.rb   # Customer data retrieval
│   ├── create_lead_tool.rb  # Sales lead generation
│   ├── create_checkout_tool.rb # Payment link generation
│   ├── search_docs_tool.rb  # Knowledge base search
│   └── escalate_to_human_tool.rb # Human handoff
└── data/
    ├── customers.json       # Dummy customer database
    ├── plans.json          # Available service plans
    └── docs.json           # Troubleshooting knowledge base
```

## Learning Objectives

This example teaches you how to:

1. **Design Multi-Agent Systems**: Structure agents with clear responsibilities and communication patterns
2. **Implement Context Sharing**: Pass information between agents while maintaining thread safety
3. **Create Domain-Specific Tools**: Build tools that integrate with external systems and business logic
4. **Handle Complex Workflows**: Route requests through multiple agents based on customer needs
5. **Manage State Safely**: Maintain conversation context across agent handoffs without race conditions

## Next Steps

After exploring this example, consider:

- Adding more specialized agents (e.g., Billing Agent, Network Operations)
- Implementing real integrations with actual CRM and support systems
- Adding conversation analytics and performance monitoring
- Creating voice or chat interfaces for customer interactions
- Implementing advanced routing logic based on customer tier or issue complexity

This ISP support system demonstrates the power of the Ruby Agents SDK for building sophisticated, real-world customer service automation while maintaining clean, maintainable code architecture.
