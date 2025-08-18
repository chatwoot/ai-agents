# OpenInference Tracing for Ruby AI Agents

## Overview

This specification defines a lightweight OpenInference-compliant tracing layer for the ruby-agents library. The implementation captures multi-agent conversations, tool usage, and handoffs using OpenTelemetry, enabling observability into complex AI workflows.

## Core Concepts

### OpenInference Semantic Model

**Span Types (kinds):**
- `AGENT` - Represents an AI agent's execution lifecycle
- `LLM` - Individual LLM API calls within an agent
- `TOOL` - Tool/function executions
- `CHAIN` - Orchestration layer (AgentRunner level)

**Span Hierarchy:**
```
CHAIN span (entire conversation)
├── AGENT span (Triage Agent)
│   ├── LLM span (initial response)
│   └── LLM span (handoff decision)
├── AGENT span (Billing Agent)
│   ├── LLM span (understanding request)
│   ├── TOOL span (lookup_customer)
│   └── LLM span (response with data)
└── AGENT span (Support Agent)
    └── LLM span (final response)
```

**Key Attributes:**
- `openinference.span.kind` - Span type identifier
- `session.id` - Links multiple traces in same conversation
- `llm.model_name` - Model used (e.g., "gpt-4")
- `llm.provider` - Provider name (e.g., "openai")
- `llm.input_messages` - Hierarchical message structure
- `llm.output_messages` - Response messages
- `agent.name` - Agent identifier
- `agent.handoff.from/to/reason` - Handoff tracking

## Architecture

### Module Structure

```ruby
module Agents
  module Tracing
    # Extension for AgentRunner
    module AgentRunnerExtension
      def with_tracing(service_name:)
        # Initialize tracer if not already done
        @tracer ||= Tracer.new(service_name: service_name)
        
        # Instrument callbacks
        Instrumentation.setup_callbacks(self, @tracer)
        
        # Return self for chaining
        self
      end
    end
    
    # Internal tracer wrapper
    class Tracer
      attr_reader :otel_tracer
      
      def initialize(service_name:)
        @provider = init_tracer_provider(service_name)
        @otel_tracer = @provider.tracer("agents-tracer", Agents::VERSION)
      end
      
      def shutdown
        @provider.shutdown
      end
    end
    
    # Internal instrumentation setup
    class Instrumentation
      def self.setup_callbacks(runner, tracer)
        # Attaches to existing callbacks
        instrument_callbacks(runner, tracer)
      end
    end
    
    # Span builders for different contexts
    class SpanBuilder
      def self.build_chain_span(tracer, name)
      def self.build_agent_span(tracer, agent_name, parent_context)
      def self.build_llm_span(tracer, model_info, parent_context)
      def self.build_tool_span(tracer, tool_name, parent_context)
    end
    
    # Attribute extraction and formatting
    class AttributeExtractor
      def self.extract_llm_attributes(context, response)
      def self.extract_agent_attributes(agent)
      def self.extract_tool_attributes(tool, args, result)
      def self.format_messages(messages)
    end
    
    # Context management for session tracking
    class SessionContext
      def self.with_session(session_id, &block)
      def self.current_session_id
    end
  end
end
```

### Integration Points

**AgentRunner Callbacks:**
```ruby
runner.on_agent_thinking do |agent_name, input|
  # Start AGENT span
end

runner.on_tool_start do |tool_name, args|
  # Start TOOL span
end

runner.on_tool_complete do |tool_name, result|
  # End TOOL span with result
end

runner.on_agent_handoff do |from, to, reason|
  # End current AGENT span, start new AGENT span
  # Record handoff attributes
end
```

**RubyLLM Callbacks (via Agent):**
```ruby
chat.on_new_message do
  # Start LLM span
end

chat.on_end_message do |response|
  # End LLM span with response attributes
end

chat.on_tool_call do |tool_call|
  # Start TOOL span
end

chat.on_tool_result do |result|
  # End TOOL span
end
```

## Implementation Details

### Span Creation

```ruby
class SpanBuilder
  def self.build_chain_span(tracer, name)
    tracer.in_span(
      name,
      attributes: {
        "openinference.span.kind" => "CHAIN",
        "session.id" => SessionContext.current_session_id
      },
      kind: :internal
    )
  end
  
  def self.build_agent_span(tracer, agent_name, parent_context)
    tracer.in_span(
      "#{agent_name} Agent",
      attributes: {
        "openinference.span.kind" => "AGENT",
        "agent.name" => agent_name,
        "session.id" => SessionContext.current_session_id
      },
      kind: :internal
    )
  end
  
  def self.build_llm_span(tracer, model_info, parent_context)
    tracer.in_span(
      "ChatCompletion",
      attributes: {
        "openinference.span.kind" => "LLM",
        "llm.model_name" => model_info[:model],
        "llm.provider" => model_info[:provider],
        "session.id" => SessionContext.current_session_id
      },
      kind: :client
    )
  end
end
```

### Message Attribute Format

Messages follow hierarchical attribute naming:

```ruby
def self.format_messages(messages)
  attributes = {}
  
  messages.each_with_index do |msg, idx|
    base = "llm.input_messages.#{idx}"
    attributes["#{base}.message.role"] = msg[:role]
    
    if msg[:content].is_a?(String)
      attributes["#{base}.message.content"] = msg[:content]
    elsif msg[:content].is_a?(Array)
      # Handle content blocks
      msg[:content].each_with_index do |block, block_idx|
        content_base = "#{base}.message.contents.#{block_idx}"
        attributes["#{content_base}.type"] = block[:type]
        attributes["#{content_base}.text"] = block[:text] if block[:type] == "text"
      end
    end
    
    # Handle tool calls
    if msg[:tool_calls]
      msg[:tool_calls].each_with_index do |call, call_idx|
        tool_base = "#{base}.message.tool_calls.#{call_idx}.tool_call"
        attributes["#{tool_base}.id"] = call[:id]
        attributes["#{tool_base}.function.name"] = call[:function][:name]
        attributes["#{tool_base}.function.arguments"] = call[:function][:arguments].to_json
      end
    end
  end
  
  attributes
end
```

### Handoff Tracking

```ruby
class Instrumentation
  def self.instrument_handoff(runner, tracer)
    current_agent_span = nil
    
    runner.on_agent_thinking do |agent_name, input|
      # Start new agent span
      current_agent_span = tracer.start_span(
        "#{agent_name} Agent",
        attributes: {
          "openinference.span.kind" => "AGENT",
          "agent.name" => agent_name,
          "input.value" => input,
          "input.mime_type" => "text/plain"
        }
      )
      
      # Make it current context for child spans
      context = OpenTelemetry::Trace.context_with_span(current_agent_span)
      OpenTelemetry::Context.attach(context)
    end
    
    runner.on_agent_handoff do |from_agent, to_agent, reason|
      if current_agent_span
        # Record handoff as event
        current_agent_span.add_event(
          "agent.handoff",
          attributes: {
            "agent.handoff.from" => from_agent,
            "agent.handoff.to" => to_agent,
            "agent.handoff.reason" => reason
          }
        )
        
        # End current agent span
        current_agent_span.set_attribute("output.value", reason)
        current_agent_span.set_attribute("output.mime_type", "text/plain")
        current_agent_span.finish
      end
      
      # New agent span will be created on next on_agent_thinking
    end
  end
end
```

### Session Management

```ruby
module Agents
  module Tracing
    class SessionContext
      SESSION_ID_KEY = :agents_session_id
      
      def self.with_session(session_id)
        token = OpenTelemetry::Context.attach(
          OpenTelemetry::Context.current.set_value(SESSION_ID_KEY, session_id)
        )
        yield
      ensure
        OpenTelemetry::Context.detach(token)
      end
      
      def self.current_session_id
        OpenTelemetry::Context.current.value(SESSION_ID_KEY)
      end
    end
  end
end
```

### Usage API

```ruby
# Create agents
triage = Agent.new(name: "Triage", instructions: "...")
billing = Agent.new(name: "Billing", instructions: "...")
support = Agent.new(name: "Support", instructions: "...")

# Create runner with tracing enabled
runner = AgentRunner
  .with_agents(triage, billing, support)
  .with_tracing(service_name: "customer-support-ai")

# Use with session tracking
Agents::Tracing::SessionContext.with_session("session-123") do
  result = runner.run("I have a billing question")
  # All spans get session.id = "session-123"
  
  # Continue conversation
  result = runner.run("What about refunds?", context: result.context)
  # New trace but same session.id
end

# Or without session tracking (each run gets a unique trace)
result = runner.run("Hello")
```

### Implementation Details

```ruby
# Extension included in AgentRunner
class AgentRunner
  include Agents::Tracing::AgentRunnerExtension
  
  # ... rest of AgentRunner implementation
end
```

### Tracer Initialization

```ruby
def init_tracer_provider(service_name)
  OpenTelemetry::SDK.configure do |c|
    c.service_name = service_name
    c.use 'OpenTelemetry::Exporter::OTLP'
    # OTLP endpoint from ENV['OTEL_EXPORTER_OTLP_ENDPOINT']
    # Defaults to http://localhost:4318/v1/traces
  end
  
  OpenTelemetry.tracer_provider
end
```

## Attribute Reference

### CHAIN Span Attributes
- `openinference.span.kind` = "CHAIN"
- `session.id` - Conversation session identifier
- `input.value` - Initial user input
- `output.value` - Final response

### AGENT Span Attributes
- `openinference.span.kind` = "AGENT"
- `agent.name` - Agent identifier
- `agent.instructions` - Agent's system instructions (optional)
- `agent.handoff.from` - Previous agent (if handoff)
- `agent.handoff.to` - Next agent (if handoff)
- `agent.handoff.reason` - Handoff reasoning
- `input.value` - Input to this agent
- `output.value` - Agent's output/decision

### LLM Span Attributes
- `openinference.span.kind` = "LLM"
- `llm.model_name` - e.g., "gpt-4o-mini"
- `llm.provider` - e.g., "openai"
- `llm.invocation_parameters` - JSON of temperature, max_tokens, etc.
- `llm.input_messages.*` - Hierarchical message structure
- `llm.output_messages.*` - Response message structure
- `llm.token_count.prompt` - Input tokens
- `llm.token_count.completion` - Output tokens
- `llm.token_count.total` - Total tokens

### TOOL Span Attributes
- `openinference.span.kind` = "TOOL"
- `tool.name` - Tool identifier
- `tool.description` - Tool purpose
- `tool.parameters` - JSON schema of parameters
- `input.value` - JSON arguments passed
- `output.value` - JSON result returned

## Design Decisions

1. **Callback-Based**: Leverages existing callback infrastructure rather than monkey-patching
2. **Non-Intrusive**: Tracing enabled via simple `with_tracing` method call
3. **Single Exporter**: OTLP-only for simplicity (industry standard)
4. **Context Propagation**: Uses OpenTelemetry's built-in context for thread-safe span relationships
5. **Session Tracking**: Explicit session management via context API
6. **Hierarchical Attributes**: Follows OpenInference convention for nested data structures
7. **Minimal Dependencies**: Only requires OpenTelemetry Ruby SDK

## Performance Considerations

1. **Lazy Attribute Evaluation**: Large payloads (messages) only serialized when span exports
2. **Batch Export**: Use BatchSpanProcessor for production to minimize overhead
3. **Sampling**: Rely on OpenTelemetry's sampling configuration
4. **Attribute Limits**: Default to 10k attributes per span for large conversations

## Future Extensions

1. **Streaming Support**: Track token-by-token streaming responses
2. **Cost Tracking**: Add token cost calculations based on model pricing
3. **Error Enrichment**: Enhanced error context for debugging
4. **Metric Extraction**: Derive metrics from trace data (latency, token usage)
5. **Custom Span Kinds**: Support for RETRIEVER, EMBEDDING, RERANKER spans