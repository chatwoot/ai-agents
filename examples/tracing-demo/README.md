# OpenInference Tracing Demo

This example demonstrates how to enable OpenInference-compliant tracing for your multi-agent conversations.

## Setup

1. Add OpenTelemetry dependencies to your Gemfile:
```ruby
gem 'opentelemetry-sdk', '~> 1.0'
gem 'opentelemetry-exporter-otlp', '~> 0.20'
```

2. Set up a tracing backend (optional - Phoenix/Arize AI, Jaeger, etc.):
```bash
# For local testing with Jaeger
docker run -d --name jaeger \
  -p 16686:16686 \
  -p 14268:14268 \
  -p 4317:4317 \
  -p 4318:4318 \
  jaegertracing/all-in-one:latest

# Set OTLP endpoint (optional, defaults to localhost:4318)
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
```

3. Run the example:
```bash
OPENAI_API_KEY=your_key ruby examples/tracing-demo/basic.rb
```

## What Gets Traced

- **CHAIN spans**: Overall conversation flows
- **AGENT spans**: Individual agent executions with handoff tracking  
- **TOOL spans**: Tool calls and their results
- **LLM spans**: Coming soon (requires RubyLLM integration)

## Session Tracking

Use session context to link multiple conversations:

```ruby
Agents::Tracing::SessionContext.with_session("user-123-session") do
  result = runner.run("Hello")
  result = runner.run("Continue conversation", context: result.context)
end
```