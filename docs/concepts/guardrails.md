---
layout: default
title: Guardrails
parent: Concepts
nav_order: 8
---

# Guardrails

Guardrails are composable validation layers that intercept content before it reaches an agent (input guards) and before it returns to the caller (output guards). They allow you to enforce policies, redact sensitive data, and abort runs when content violates your rules.

## How Guards Work

A guard is a stateless class that receives content and returns one of three outcomes:

- **Pass** (return `nil` or `GuardResult.pass`): Content is acceptable, continue execution.
- **Rewrite** (`GuardResult.rewrite`): Replace the content with a modified version.
- **Tripwire** (`GuardResult.tripwire`): Abort the run immediately with an error.

```ruby
class PiiRedactor < Agents::Guard
  guard_name "pii_redactor"
  description "Redacts Social Security numbers from content"

  def call(content, context)
    redacted = content.gsub(/\b\d{3}-\d{2}-\d{4}\b/, "[REDACTED]")
    GuardResult.rewrite(redacted, message: "SSN redacted") if redacted != content
  end
end
```

## Input Guards vs Output Guards

**Input guards** run before the first LLM call. They validate or transform the user's message before the agent sees it. Use them for prompt injection detection, input sanitization, or content filtering.

**Output guards** run on the agent's final response before it returns to the caller. They validate or transform what the agent says back. Use them for PII redaction, topic fencing, or response quality checks.

```ruby
agent = Agents::Agent.new(
  name: "Support",
  instructions: "You are a helpful support agent.",
  input_guards: [PromptInjectionGuard.new],
  output_guards: [PiiRedactor.new, TopicFence.new]
)
```

Guards execute in array order. Each guard sees the output of the previous guard's potential rewrite, forming a processing pipeline.

## Writing a Guard

Extend `Agents::Guard` and implement the `call` method:

```ruby
class MaxLengthGuard < Agents::Guard
  guard_name "max_length"
  description "Tripwires if content exceeds maximum length"

  def initialize(max:)
    super()
    @max = max
  end

  def call(content, context)
    if content.length > @max
      GuardResult.tripwire(
        message: "Content exceeds #{@max} characters",
        metadata: { length: content.length, max: @max }
      )
    end
  end
end
```

Guards follow the same thread-safety principles as Tools:
- No execution state in instance variables (only configuration like `@max` above)
- All shared state flows through the `context` parameter
- Guard instances are immutable after creation

## Tripwires

When a guard tripwires, the run aborts immediately. The result includes structured metadata about what happened:

```ruby
result = runner.run("Tell me a secret")

if result.tripwired?
  puts result.guardrail_tripwire[:guard_name]  # => "content_policy"
  puts result.guardrail_tripwire[:message]     # => "Response violates content policy"
  puts result.guardrail_tripwire[:metadata]    # => { category: "secrets" }
end
```

Tripwires short-circuit the guard chain. If guard 1 tripwires, guards 2 and 3 never run.

## Fail-Open vs Fail-Closed

By default, guards are **fail-open**: if a guard raises an unexpected exception (not a Tripwire), the error is logged and the guard is skipped. This prevents a buggy guard from breaking your entire application.

For high-security contexts, you can configure **fail-closed** (strict) mode on the agent. In strict mode, any unexpected guard exception is converted to a tripwire:

```ruby
# Fail-open (default) — buggy guard is skipped, run continues
agent = Agents::Agent.new(
  name: "Support",
  input_guards: [PotentiallyBuggyGuard.new]
)

# Fail-closed — any guard error aborts the run
# (configured via GuardRunner strict: true, typically set at the runner level)
```

## Structured Output

When an agent uses `response_schema`, the LLM returns structured data (a Hash). Output guards still receive a String — the SDK automatically serializes the Hash to JSON before the guard chain and deserializes it back after any rewrite. This means your guards always operate on Strings regardless of output format.

```ruby
# This guard works on both plain text and structured output
class ContentFilter < Agents::Guard
  guard_name "content_filter"

  def call(content, context)
    # content is always a String — JSON for structured output
    if content.include?("forbidden")
      GuardResult.tripwire(message: "Forbidden content detected")
    end
  end
end
```

## Guards Across Handoffs

Guards are agent-scoped. When agent A hands off to agent B:

- Agent A's **input guards** ran once on the original user input (before the handoff decision).
- Agent A's **output guards** do NOT run — the handoff interrupts before a final response.
- Agent B's **output guards** run on agent B's final response.

This means each agent enforces its own policies independently.

## Callbacks and Instrumentation

Guard activity is observable through the callback system:

```ruby
runner = Agents::Runner.with_agents(agent)
  .on_guard_triggered { |guard_name, phase, action, message, ctx|
    puts "Guard #{guard_name} (#{phase}): #{action} — #{message}"
  }
```

The callback fires for every non-pass result (rewrites and tripwires). It does not fire when guards pass.

If OpenTelemetry instrumentation is installed, guard events produce `agents.run.guard.*` spans with attributes for guard name, phase (input/output), action (rewrite/tripwire), and message.

## Complete Example

```ruby
class PromptInjectionGuard < Agents::Guard
  guard_name "prompt_injection"
  description "Detects common prompt injection patterns"

  def call(content, context)
    patterns = [
      /ignore\s+(all\s+)?previous\s+instructions/i,
      /you\s+are\s+now\s+a/i,
      /disregard\s+(all\s+)?prior/i
    ]

    if patterns.any? { |p| content.match?(p) }
      GuardResult.tripwire(
        message: "Potential prompt injection detected",
        metadata: { input_length: content.length }
      )
    end
  end
end

class PiiRedactor < Agents::Guard
  guard_name "pii_redactor"
  description "Redacts SSNs and email addresses"

  def call(content, context)
    redacted = content
      .gsub(/\b\d{3}-\d{2}-\d{4}\b/, "[SSN REDACTED]")
      .gsub(/\b[\w.+-]+@[\w-]+\.[\w.]+\b/, "[EMAIL REDACTED]")

    GuardResult.rewrite(redacted, message: "PII redacted") if redacted != content
  end
end

agent = Agents::Agent.new(
  name: "Support",
  instructions: "You are a helpful customer support agent.",
  input_guards: [PromptInjectionGuard.new],
  output_guards: [PiiRedactor.new]
)

runner = Agents::Runner.with_agents(agent)
  .on_guard_triggered { |name, phase, action, msg|
    Rails.logger.info("Guard #{name} (#{phase}): #{action}")
  }

result = runner.run("What is my email?")
# Output PII is automatically redacted before reaching the user
```
