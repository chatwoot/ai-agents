---
layout: default
title: Callbacks
parent: Concepts
nav_order: 6
---

# Real-time Callbacks

The AI Agents SDK provides real-time callbacks that allow you to monitor agent execution as it happens. This is particularly useful for building user interfaces that show live feedback about what agents are doing.

## Available Callbacks

The SDK provides four types of callbacks that give you visibility into different stages of agent execution:

**Agent Thinking** - Triggered when an agent is about to make an LLM call. Useful for showing "thinking" indicators in UIs.

**Tool Start** - Called when an agent begins executing a tool. Shows which tool is being used and with what arguments.

**Tool Complete** - Triggered when a tool finishes execution. Provides the tool name and result for status updates.

**Agent Handoff** - Called when control transfers between agents. Shows the source agent, target agent, and handoff reason.

## Basic Usage

Callbacks are registered on the AgentRunner using chainable methods:

```ruby
runner = Agents::AgentRunner.with_agents(triage, support)
  .on_agent_thinking { |agent, input| puts "#{agent} thinking..." }
  .on_tool_start { |tool, args| puts "Using #{tool}" }
  .on_tool_complete { |tool, result| puts "#{tool} completed" }
  .on_agent_handoff { |from, to, reason| puts "#{from} → #{to}" }
```

## Integration Patterns

Callbacks work well with real-time web frameworks like Rails ActionCable, allowing you to stream agent status updates directly to browser clients. They're also useful for logging, metrics collection, and building debug interfaces.

## Thread Safety

Callbacks execute synchronously in the same thread as agent execution. Exceptions in callbacks are caught and logged as warnings without interrupting agent operation. For heavy operations or external API calls, consider using background jobs triggered by the callbacks.
