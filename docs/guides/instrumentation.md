---
layout: default
title: OpenTelemetry Instrumentation
parent: Guides
nav_order: 7
---

# OpenTelemetry Instrumentation

Trace agent execution, LLM calls, tool usage, and handoffs using OpenTelemetry. Compatible with [Langfuse](https://langfuse.com) and any OTel-compatible backend.

## Overview

The `Agents::Instrumentation` module produces OTel spans that give you full visibility into agent execution:

- **LLM generation spans** with model name, token counts, and input/output
- **Tool execution spans** with arguments and results
- **Agent container spans** grouping related LLM and tool calls
- **Handoff events** recording agent-to-agent transfers

Spans follow the [GenAI semantic conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/) and include Langfuse-specific attributes for rich rendering in the Langfuse dashboard.

## Setup

### 1. Install dependencies

Add to your Gemfile:

```ruby
gem "opentelemetry-sdk"
gem "opentelemetry-exporter-otlp"
```

Then run `bundle install`.

### 2. Configure the OTel SDK

```ruby
require "opentelemetry-sdk"
require "opentelemetry-exporter-otlp"

OpenTelemetry::SDK.configure do |c|
  c.add_span_processor(
    OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(
      OpenTelemetry::Exporter::OTLP::Exporter.new(
        endpoint: "https://your-otel-endpoint/v1/traces",
        headers: { "Authorization" => "Bearer YOUR_TOKEN" }
      )
    )
  )
end
```

### 3. Install on a runner

```ruby
require "agents/instrumentation"

tracer = OpenTelemetry.tracer_provider.tracer("my-app")
runner = Agents::Runner.with_agents(triage, billing, support)

Agents::Instrumentation.install(runner, tracer: tracer)
```

That's it. Every `runner.run(...)` call now produces OTel spans.

## Span Hierarchy

```
root (agents.run)
├── agent.Calculator           # container span per agent (no model attr)
│   ├── agents.run.generation  # GENERATION: model, tokens, I/O
│   ├── agents.run.tool.add    # TOOL: arguments + result
│   └── agents.run.generation  # second LLM call after tool result
├── agent.Support              # after handoff
│   └── agents.run.generation
└── agents.run.handoff         # point event on root span
```

**Only GENERATION spans carry `gen_ai.request.model`**. This prevents Langfuse from double-counting costs when it sums token usage across spans with a model attribute.

## Configuration Options

### `trace_name`

Custom name for the root span (default: `"agents.run"`):

```ruby
Agents::Instrumentation.install(runner,
  tracer: tracer,
  trace_name: "customer_support.run"
)
```

Child spans derive their names: `customer_support.run.generation`, `customer_support.run.tool.add_numbers`, etc.

### `span_attributes`

Static attributes applied to the root span:

```ruby
Agents::Instrumentation.install(runner,
  tracer: tracer,
  span_attributes: {
    "langfuse.trace.tags" => '["production","v2"]',
    "langfuse.session.id" => session_id
  }
)
```

### `attribute_provider`

A lambda that receives the context wrapper and returns dynamic attributes:

```ruby
Agents::Instrumentation.install(runner,
  tracer: tracer,
  attribute_provider: ->(ctx) {
    {
      "langfuse.user.id" => ctx.context[:user_id].to_s,
      "langfuse.session.id" => ctx.context[:session_id].to_s
    }
  }
)
```

## Langfuse Integration

### Endpoint and Authentication

Langfuse accepts OTel traces at `{LANGFUSE_HOST}/api/public/otel/v1/traces`. Authentication uses HTTP Basic with your public and secret keys:

```ruby
require "base64"

langfuse_host = ENV["LANGFUSE_HOST"] # e.g. "https://cloud.langfuse.com"
langfuse_pk   = ENV["LANGFUSE_PUBLIC_KEY"]
langfuse_sk   = ENV["LANGFUSE_SECRET_KEY"]

auth_token = Base64.strict_encode64("#{langfuse_pk}:#{langfuse_sk}")

OpenTelemetry::SDK.configure do |c|
  c.add_span_processor(
    OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(
      OpenTelemetry::Exporter::OTLP::Exporter.new(
        endpoint: "#{langfuse_host}/api/public/otel/v1/traces",
        headers: { "Authorization" => "Basic #{auth_token}" }
      )
    )
  )
end
```

### Attribute Mapping

The instrumentation sets Langfuse-specific attributes that map to the Langfuse UI:

| Attribute | Set On | Langfuse Display |
|-----------|--------|-----------------|
| `langfuse.trace.input` | Root span | Trace input (top of page) |
| `langfuse.trace.output` | Root span | Trace output (top of page) |
| `langfuse.observation.input` | All spans | Observation input (sidebar click) |
| `langfuse.observation.output` | All spans | Observation output (sidebar click) |
| `langfuse.observation.type` | Tool spans | `"tool"` type indicator |
| `langfuse.user.id` | Root span (via attribute_provider) | User filter/display |
| `langfuse.session.id` | Root span (via attribute_provider) | Session grouping |
| `langfuse.trace.tags` | Root span (via span_attributes) | Trace tags |
| `gen_ai.request.model` | Generation spans only | Model name + cost calculation |
| `gen_ai.usage.input_tokens` | Generation spans | Token usage |
| `gen_ai.usage.output_tokens` | Generation spans | Token usage |

### EU vs US Cloud

- **US**: `https://cloud.langfuse.com`
- **EU**: `https://eu.cloud.langfuse.com`

Set `LANGFUSE_HOST` accordingly. Self-hosted instances use your own URL.

## Complete Example

```ruby
require "agents"
require "agents/instrumentation"
require "opentelemetry-sdk"
require "opentelemetry-exporter-otlp"
require "base64"

# --- Configure Agents ---
Agents.configure do |config|
  config.openai_api_key = ENV["OPENAI_API_KEY"]
  config.default_model = "gpt-4o-mini"
end

# --- Configure OTel with Langfuse ---
langfuse_host = ENV.fetch("LANGFUSE_HOST", "https://cloud.langfuse.com")
auth_token = Base64.strict_encode64(
  "#{ENV["LANGFUSE_PUBLIC_KEY"]}:#{ENV["LANGFUSE_SECRET_KEY"]}"
)

OpenTelemetry::SDK.configure do |c|
  c.add_span_processor(
    OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(
      OpenTelemetry::Exporter::OTLP::Exporter.new(
        endpoint: "#{langfuse_host}/api/public/otel/v1/traces",
        headers: { "Authorization" => "Basic #{auth_token}" }
      )
    )
  )
end

tracer = OpenTelemetry.tracer_provider.tracer("my-app")

# --- Build agents ---
triage = Agents::Agent.new(name: "Triage", instructions: "Route users...")
billing = Agents::Agent.new(name: "Billing", instructions: "Handle billing...")
support = Agents::Agent.new(name: "Support", instructions: "Technical support...")

triage.register_handoffs(billing, support)
billing.register_handoffs(triage)
support.register_handoffs(triage)

# --- Create runner with instrumentation ---
runner = Agents::Runner.with_agents(triage, billing, support)

Agents::Instrumentation.install(runner,
  tracer: tracer,
  trace_name: "customer_support",
  attribute_provider: ->(ctx) {
    {
      "langfuse.user.id" => ctx.context[:user_id].to_s,
      "langfuse.session.id" => ctx.context[:session_id].to_s
    }
  }
)

# --- Run conversations ---
result = runner.run("I have a billing question",
  context: { user_id: "user_123", session_id: "sess_456" })

puts result.output

# Ensure spans are flushed before exit
at_exit { OpenTelemetry.tracer_provider.force_flush }
```

## Troubleshooting

### "undefined" values in Langfuse

Langfuse renders empty string attributes as "undefined". The instrumentation guards against this by not setting attributes when values are nil or empty. If you see "undefined", check that your agents are producing output content.

### Double-counted costs

If token costs appear inflated, verify that `gen_ai.request.model` is only set on GENERATION spans, not on container or root spans. The built-in instrumentation handles this correctly. If you set custom `span_attributes` that include `gen_ai.request.model`, costs will be double-counted.

### Empty spans / missing data

- Ensure `opentelemetry-sdk` is installed (not just `opentelemetry-api`)
- Call `OpenTelemetry.tracer_provider.force_flush` before process exit
- Verify your OTLP endpoint is reachable and credentials are correct
- Check that `Agents::Instrumentation.install` returns the runner (returns nil if OTel is unavailable)

### Spans not appearing in Langfuse

- Verify the endpoint includes `/api/public/otel/v1/traces`
- Check that the Authorization header uses `Basic` (not `Bearer`) with base64-encoded `pk:sk`
- Use `BatchSpanProcessor` for production; `SimpleSpanProcessor` can be useful for debugging
- **SSL CRL errors on Ruby 3.4+**: The OTLP exporter silently fails when SSL certificate revocation list (CRL) checks fail. The exporter reports SUCCESS but no data arrives. Fix by passing `ssl_verify_mode: OpenSSL::SSL::VERIFY_NONE` to the exporter in development, or ensure your system CA certificates are up to date
