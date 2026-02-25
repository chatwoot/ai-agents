---
layout: default
title: Provider-Specific Parameters
parent: Guides
nav_order: 7
---

# Provider-Specific Parameters

Provider-specific parameters let you pass additional options directly into the LLM request payload via RubyLLM's `with_params` method. This is useful for features like OpenAI's `service_tier`, Anthropic's `reasoning_effort`, or any other provider-specific option that isn't exposed as a first-class SDK attribute.

## Basic Usage

### Agent-Level Params

Set default parameters when creating an agent that will be applied to all requests:

```ruby
agent = Agents::Agent.new(
  name: "Assistant",
  instructions: "You are a helpful assistant",
  params: {
    service_tier: "flex",
    max_completion_tokens: 2048
  }
)

runner = Agents::Runner.with_agents(agent)
result = runner.run("Hello!")
# All requests will include the provider-specific params
```

### Runtime Params

Override or add parameters for specific requests:

```ruby
agent = Agents::Agent.new(
  name: "Assistant",
  instructions: "You are a helpful assistant"
)

runner = Agents::Runner.with_agents(agent)

# Pass params at runtime
result = runner.run(
  "Explain quantum computing",
  params: {
    service_tier: "default",
    max_completion_tokens: 4096
  }
)
```

### Parameter Precedence

When both agent-level and runtime params are provided, **runtime params take precedence**:

```ruby
agent = Agents::Agent.new(
  name: "Assistant",
  instructions: "You are a helpful assistant",
  params: {
    service_tier: "flex",
    top_p: 0.9
  }
)

runner = Agents::Runner.with_agents(agent)

result = runner.run(
  "Hello!",
  params: {
    service_tier: "default",       # Overrides agent's flex value
    max_completion_tokens: 1000    # Additional param
  }
)

# Final params sent to LLM API:
# {
#   service_tier: "default",          # Runtime value wins
#   top_p: 0.9,                       # From agent
#   max_completion_tokens: 1000       # From runtime
# }
```

## See Also

- [Custom Request Headers](request-headers.html) - Adding custom HTTP headers using the same two-level precedence pattern
- [Multi-Agent Systems](multi-agent-systems.html) - Using params across agent handoffs
