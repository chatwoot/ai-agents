---
layout: default
title: Handoffs
parent: Concepts
nav_order: 4
---

# Handoffs

**Handoffs** are a powerful feature of the Ruby Agents library that allow you to build sophisticated multi-agent systems. A handoff is the process of transferring a conversation from one agent to another, more specialized agent.

This is particularly useful when you have a general-purpose agent that can handle a wide range of queries, but you also have specialized agents that are better equipped to handle specific tasks. For example, you might have a triage agent that routes users to a billing agent or a technical support agent.

## How Handoffs Work

Handoffs are implemented as a special type of tool called a `HandoffTool`. When you configure an agent with `handoff_agents`, the library automatically creates a `HandoffTool` for each of the specified agents.

Here's how the handoff process works:

1.  **The user sends a message:** The user sends a message that indicates they need help with a specific task (e.g., "I have a problem with my bill").
2.  **The LLM decides to hand off:** The current agent's language model determines that the query is best handled by another agent and decides to call the corresponding `HandoffTool`.
3.  **The `HandoffTool` signals the handoff:** The `HandoffTool` sets a `pending_handoff` flag in the `RunContext`, indicating which agent to hand off to.
4.  **The Runner switches agents:** The `Runner` detects the `pending_handoff` flag and switches the `current_agent` to the new agent.
5.  **The conversation continues:** The conversation continues with the new agent, which now has access to the full conversation history.

### Concurrent Handoff Selection

Only one handoff can be pending at a time. The first handoff accepted by the run context wins, and later handoff executions cannot overwrite it. This guarantee is thread-safe even when a tool executor runs calls concurrently.

"First" refers to execution order, not necessarily the order of tool calls in the model response. Applications that require model-order priority should ensure their tool executor preserves that order.

This selection rule does not prevent sequential loops across agent turns. Use distinct agent scopes and an application-level turn or handoff limit when cyclic routing is possible.

## Why Use Tools for Handoffs?

Using tools for handoffs has several advantages over simply instructing the LLM to hand off the conversation:

*   **Reliability:** LLMs are very good at using tools when they are available. By representing handoffs as tools, we can be more confident that the LLM will use them when appropriate.
*   **Clarity:** The tool's schema clearly defines when each handoff is suitable, making it easier for the LLM to make the right decision.
*   **Simplicity:** We don't need to parse free-text responses from the LLM to determine if a handoff is needed.
*   **Consistency:** This approach works consistently across different LLM providers.

## Example

```ruby
# Create the specialized agents
billing_agent = Agents::Agent.new(name: "Billing", instructions: "Handle billing and payment issues.")
support_agent = Agents::Agent.new(name: "Support", instructions: "Provide technical support.")

# Create the triage agent with handoff agents
triage_agent = Agents::Agent.new(
  name: "Triage",
  instructions: "You are a triage agent. Your job is to route users to the correct department.",
  handoff_agents: [billing_agent, support_agent]
)

# Run the triage agent
result = Agents::Runner.run(triage_agent, "I have a problem with my bill.")

# The runner will automatically hand off to the billing agent
```

In this example, the `triage_agent` will automatically hand off the conversation to the `billing_agent` when the user asks a question about their bill. This allows you to create a seamless user experience where the user is always talking to the most qualified agent for their needs.

## Custom Handoff Tools

`register_handoffs` remains the simplest option and continues to create parameterless `HandoffTool` instances. Use `register_handoff` when one relationship needs a custom schema, operational metadata, or an acceptance hook.

```ruby
class DelegationTool < Agents::HandoffTool
  description "Delegate work with the context needed by the destination agent"

  param :reason, type: "string", desc: "Why this destination is required"
  param :summary, type: "string", desc: "Relevant operational context"

  def perform(tool_context, reason:, summary:)
    prepare_handoff(
      tool_context,
      reason: reason,
      metadata: { summary: summary },
      message: "Delegating to #{target_agent.name}"
    )
  end
end

triage.register_handoff(
  billing,
  tool_factory: lambda do |source_agent:, target_agent:|
    DelegationTool.new(target_agent)
  end,
  on_handoff: lambda do |run_context, handoff_info|
    run_context.context[:delegation] = handoff_info[:metadata]
  end
)
```

The tool factory receives `source_agent:` and `target_agent:` keyword arguments. It must return an `Agents::HandoffTool` configured for the registered target. A custom tool defines its own parameters and calls the protected `prepare_handoff` method with any optional `reason`, `metadata`, and halt `message`.

The acceptance hook receives the current `RunContext` and the complete handoff information before the destination agent is configured. Hook failures fail the run instead of silently continuing with partially applied context.

Configure all handoff relationships before using an agent with a runner. Do not mutate `handoffs`, `handoff_agents`, or replace relationships while a run is in progress; runtime relationship reconfiguration is not supported.

### Callback Data

The `agent_handoff` callback now receives two optional trailing values:

```ruby
lambda do |from_agent, to_agent, reason, run_context, metadata|
  # Observe the accepted handoff.
end
```

Existing strict lambdas with the original three or four arguments remain compatible because callback dispatch slices trailing arguments to the callback's accepted arity.

### Lifetime and Trust Boundary

Handoff metadata is temporary execution state. The runner consumes it during the current handoff and does not automatically add it to the conversation history, system prompt, or a future run. Persist only the durable facts your application actually needs.

Metadata may contain model-generated or user-derived content. Treat it as untrusted operational data. A hook that injects metadata into a destination prompt should state explicitly that the data cannot override the destination agent's role, guardrails, tool requirements, or authorization rules.

## Troubleshooting Handoffs

### Infinite Handoff Loops

**Problem:** Agents keep handing off to each other in an endless loop.

**Common Causes:**
- Agent instructions that conflict with each other
- Agents configured to hand off for overlapping scenarios
- Poor instruction clarity about when to hand off vs. when to handle directly

**Solutions:**
1. **Review agent instructions:** Ensure each agent has a clear, distinct responsibility
2. **Use hub-and-spoke pattern:** Have specialized agents only hand off back to a central triage agent
3. **Add specific scenarios:** Include examples in instructions of when to handle vs. hand off
4. **Enable debug logging:** Use `ENV["RUBYLLM_DEBUG"] = "true"` to see handoff decisions


### Multiple Handoffs in One Response

The library atomically accepts one pending handoff. Any later handoff tool execution receives a rejection result and cannot replace the accepted destination. With concurrent executors, the first tool execution accepted by the run context wins.
