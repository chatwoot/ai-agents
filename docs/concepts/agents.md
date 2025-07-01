---
layout: default
title: Agents
parent: Concepts
nav_order: 1
---

# Agents

An **Agent** is the fundamental building block of the library. It represents an AI assistant with a specific set of capabilities, defined by its instructions, tools, and the underlying language model it uses.

Agents are immutable and thread-safe by design. Once created, their configuration cannot be changed, ensuring safe sharing across multiple threads without race conditions. Agents can have dynamic instructions using Proc objects that receive runtime context.

### Key Attributes of an Agent

*   **`name`**: A unique name for the agent, used for identification and in handoffs.
*   **`instructions`**: The system prompt that guides the agent's behavior. This can be a static string or a `Proc` that dynamically generates instructions based on the current context.
*   **`model`**: The language model the agent will use (e.g., `"gpt-4.1-mini"`).
*   **`tools`**: An array of `Agents::Tool` instances that the agent can use to perform actions.
*   **`handoff_agents`**: An array of other agents that this agent can hand off conversations to.

### Example

```ruby
# Create a simple agent
assistant_agent = Agents::Agent.new(
  name: "Assistant",
  instructions: "You are a helpful assistant.",
  model: "gpt-4.1-mini",
  tools: [CalculatorTool.new]
)

# Create a specialized agent by cloning the base agent
specialized_agent = assistant_agent.clone(
  instructions: "You are a specialized assistant for financial calculations.",
  tools: assistant_agent.tools + [FinancialDataTool.new]
)
```

In this example, we create a base `assistant_agent` and then create a `specialized_agent` by cloning it and adding a new tool. This approach allows for easy composition and reuse of agent configurations.
