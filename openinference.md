# OpenInference Python Implementation Analysis

## 1. Architecture & Core Components

### Main Classes/Modules

**Core Instrumentation Framework:**
1. **OITracer** (`_tracers.py:96`): A wrapper around OpenTelemetry's Tracer that provides OpenInference-specific functionality
   - Extends `wrapt.ObjectProxy` to wrap the OTEL tracer
   - Provides decorators for different span types: `@tracer.llm`, `@tracer.agent`, `@tracer.chain`, `@tracer.tool`
   - Uses custom ID generator to avoid seed conflicts

2. **OpenInferenceSpan** (`_spans.py:27`): A wrapper around OTEL spans that handles attribute masking and deferred setting
   - Wraps OpenTelemetry spans with configuration-aware attribute handling
   - Defers important attributes (like span kind) until span end

3. **TracerProvider** (`_tracer_providers.py:15`): Custom provider that creates OITracer instances
   - Extends OpenTelemetry's TracerProvider
   - Sets large default span attribute limits (10,000)
   - Injects TraceConfig for attribute masking

**Semantic Conventions:**
- `SpanAttributes` - Defines all OpenInference attribute names (session.id, llm.*, tool.*, etc.)
- `OpenInferenceSpanKindValues` - Enum for span types (LLM, TOOL, CHAIN, AGENT, EMBEDDING)
- Message/Tool/Document attribute schemas

**Provider-Specific Instrumentors:**
- Individual packages for each provider (OpenAI, Anthropic, LangChain, etc.)
- Each implements `BaseInstrumentor` pattern for auto-instrumentation

### Initialization & Configuration
```python
# Basic initialization with OTLP export
from opentelemetry.sdk import trace as trace_sdk
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from openinference.instrumentation import TracerProvider, TraceConfig
from openinference.instrumentation.openai import OpenAIInstrumentor

# Configure tracing with optional masking
config = TraceConfig(
    hide_inputs=True,
    hide_outputs=False,
    base64_image_max_length=32_000
)

# Create tracer provider with OTLP export
tracer_provider = TracerProvider(config=config)
tracer_provider.add_span_processor(
    SimpleSpanProcessor(OTLPSpanExporter(endpoint="http://localhost:6006/v1/traces"))
)
tracer = tracer_provider.get_tracer(__name__)

# Auto-instrument the OpenAI client
OpenAIInstrumentor().instrument(
    tracer_provider=tracer_provider,
    config=config
)
```

### Integration with LLM Clients
Integration is **non-intrusive** and uses monkey-patching:
- Wraps core client methods (e.g., `OpenAI.request`, `AsyncOpenAI.request`)
- Intercepted at the HTTP request level, not individual API methods
- Works transparently with existing code - no code changes required

### Dependencies
- **OpenTelemetry Core:** `opentelemetry-api`, `opentelemetry-sdk`
- **Export:** `opentelemetry-exporter-otlp` (or other exporters)
- **Instrumentation:** `wrapt` for monkey-patching
- **Semantic Conventions:** `openinference-semantic-conventions`
- **Provider-specific:** Each instrumentation package depends on the target library
- **Optional:** `pydantic` for model serialization support

## 2. Span Creation & Management

### Span Creation
The tracer provides multiple ways to create spans:

1. **Context Manager Pattern**:
```python
with tracer.start_as_current_span(
    "my_span",
    openinference_span_kind="llm",
    attributes={"key": "value"}
) as span:
    span.set_input(messages)
    # ... do work ...
    span.set_output(response)
```

2. **Decorator Pattern**:
```python
@tracer.llm
def my_llm_function(messages):
    # Automatically creates LLM span
    return openai_client.chat.completions.create(...)

@tracer.tool(name="weather", description="Gets weather")
def get_weather(city: str):
    # Automatically creates tool span with inferred schema
    return "sunny"
```

### Span Attributes Structure

**Core Attributes:**
- `openinference.span.kind` - Span type (LLM/TOOL/CHAIN/AGENT/EMBEDDING)
- `llm.system` - AI system (openai/anthropic/etc.)
- `llm.provider` - Provider (openai/azure/google/etc.)

**LLM Span Attributes:**
- `llm.model_name` - Model identifier
- `llm.invocation_parameters` - JSON of model parameters
- `llm.input_messages` - Hierarchical message structure
- `llm.output_messages` - Response messages
- `llm.token_count.prompt/completion/total` - Token usage
- `llm.token_count.prompt_details.cache_read/cache_write` - Cache details
- `llm.tools` - Available tools for the model

**Message Attribute Hierarchy:**
```
llm.input_messages.0.role = "user"
llm.input_messages.0.content = "Hello"
llm.input_messages.0.contents.0.type = "text"
llm.input_messages.0.contents.0.text = "Hello"
llm.input_messages.0.contents.1.type = "image"
llm.input_messages.0.contents.1.image.url = "data:image/..."
llm.input_messages.1.role = "assistant"
llm.input_messages.1.tool_calls.0.id = "call_123"
llm.input_messages.1.tool_calls.0.function.name = "get_weather"
llm.input_messages.1.tool_calls.0.function.arguments = '{"city": "SF"}'
```

**Tool Span Attributes:**
- `tool.name` - Tool name
- `tool.description` - Tool description
- `tool.parameters` - JSON schema of parameters

**Other Span Types:**
- **Chain/Agent Spans**: input/output values with mime types
- **Embedding Spans**: model name, embeddings array

### Parent-Child Relationships
- Spans automatically nest based on the OpenTelemetry context
- The tracer maintains context using `use_span` and `set_span_in_context`
- Streaming responses are handled by monkey-patching response objects

### Span Lifecycle & Timing

**Automatic Span Creation (LLM calls):**
```python
# Spans are created automatically when LLM calls are made
with tracer.start_as_current_span(
    name="ChatCompletion",  # Derived from response type
    openinference_span_kind=OpenInferenceSpanKindValues.LLM,
    attributes={
        SpanAttributes.LLM_SYSTEM: "openai",
        SpanAttributes.LLM_PROVIDER: "openai",
        # ... other attributes
    }
) as span:
    # LLM call happens here
    # Response attributes added when call completes
```

**Manual Span Creation:**
```python
# Start span (_tracers.py:143)
span = tracer.start_span(
    name=span_name,
    context=context,
    kind=kind,
    attributes=combined_attributes,
    start_time=start_time
)

# During execution
span.set_attribute(key, value)  # Masked by TraceConfig
span.record_exception(error)    # On errors

# End span (_spans.py:50)
span.end(end_time)  # Deferred attributes are set here
```

**Span Timing:**
- **Start:** When request begins (before HTTP call)
- **End:** When response completes (after processing streaming response)
- **Streaming:** Span remains open until stream consumption finishes
- **Errors:** Span marked with error status and exception details

## 3. Session/Thread Management

### Session ID Handling
Session IDs are passed through OpenTelemetry's context system:

```python
from openinference.instrumentation import using_session

# Method 1: Context manager
with using_session("my-session-123"):
    # All spans created here will have session.id = "my-session-123"
    response = llm_client.chat.completions.create(...)

# Method 2: Combined attributes
with using_attributes(
    session_id="my-session-123",
    user_id="user-456",
    metadata={"key": "value"}
):
    # Multiple context attributes at once
    ...
```

### Context Storage
- Session ID is stored in OpenTelemetry's context via `set_value()` (`context_attributes.py:52`)
- Retrieved using `get_value()` and attached to spans automatically
- Context propagates through async/sync call stacks

### Context Attributes

**Available Context Attributes:**
- `session.id` - Conversation/session identifier
- `user.id` - User identifier
- `metadata` - Custom key-value pairs (JSON)
- `tag.tags` - Categorical tags for filtering
- `llm.prompt_template.*` - Template information

**Context Propagation:**
```python
# Context automatically flows to child operations
with using_attributes(session_id="session-1", user_id="user-1"):
    @tracer.chain
    def multi_step_process():
        llm_call()     # Gets session-1, user-1
        tool_call()    # Gets session-1, user-1
        another_llm()  # Gets session-1, user-1
```

### Conversation Tracking
- Each LLM call within a session context gets the same `session.id`
- Context automatically propagates across async boundaries
- The OpenAI Agents instrumentation tracks handoffs between agents
- Uses `OrderedDict` to track in-flight handoffs with a max size limit (_MAX_HANDOFFS_IN_FLIGHT = 1000)

## 4. Callback/Hook Integration

### OpenAI Instrumentation
The OpenAI instrumentor wraps the `request` method:

```python
# _request.py:274
wrap_function_wrapper(
    module="openai",
    name="OpenAI.request",
    wrapper=_Request(tracer=tracer, openai=openai)
)
```

### Interception Pattern

**Request Wrapper Implementation:**
```python
class _Request:
    def __call__(self, wrapped, instance, args, kwargs):
        # Extract request parameters
        cast_to, request_parameters = _parse_request_args(args)

        # Start span with context
        with self._start_as_current_span(
            span_name=cast_to.__name__,
            attributes=self._get_attributes_from_request(...),
            context_attributes=get_attributes_from_context(),
        ) as span:
            # Make original call
            response = wrapped(*args, **kwargs)

            # Process response and add attributes
            return self._finalize_response(response, span, ...)
```

**Interception Points:**
1. **Pre-request**: Extract attributes from request parameters
2. **Post-request**: Handle streaming vs non-streaming responses
3. **Stream handling**: Monkey-patch stream objects to accumulate chunks

**Framework-Specific Hooks:**

**LangChain Integration:**
- Hooks into LangChain's callback system
- Wraps `BaseCallbackManager.__init__`
- Automatically traces chains, tools, and LLM calls

### Decorator Implementation
Decorators use `wrapt.decorator` for proper function wrapping:
```python
@wrapt.decorator
def sync_wrapper(wrapped, instance, args, kwargs):
    with _llm_context(...) as context:
        output = wrapped(*args, **kwargs)
        context.process_output(output)
        return output
```

### Non-intrusive Design
- Instrumentation can be disabled via `suppress_tracing()` context manager
- Uses `_SUPPRESS_INSTRUMENTATION_KEY` to skip instrumentation
- Original methods are preserved for uninstrumentation

## 5. Message & Tool Handling

### Message Capture
Messages are captured with full structure preservation:

```python
# Input messages (_attributes.py:403)
for message_index, message in enumerate(messages):
    yield f"{base_key}.{message_index}.{MESSAGE_ROLE}", role
    yield f"{base_key}.{message_index}.{MESSAGE_CONTENT}", content

    # Handle content blocks (text, images)
    for content_index, content_block in enumerate(contents):
        yield f"{base_key}.{message_index}.{MESSAGE_CONTENTS}.{content_index}.{type}", ...
```

### Tool Call Tracking
Tool calls are tracked with complete details:
```python
# Tool definitions
{
    "llm.tools.0.tool.json_schema": {
        "type": "function",
        "function": {
            "name": "get_weather",
            "parameters": {...}
        }
    }
}

# Tool calls in messages
{
    "llm.output_messages.0.message.tool_calls.0.tool_call.id": "call_123",
    "llm.output_messages.0.message.tool_calls.0.tool_call.function.name": "get_weather",
    "llm.output_messages.0.message.tool_calls.0.tool_call.function.arguments": "{\"city\":\"SF\"}"
}
```

### Streaming Handling
Streaming responses use accumulator pattern (`_response_accumulator.py`):
1. Create accumulator based on response type
2. Process each chunk through accumulator
3. Finalize accumulated attributes when stream ends

## 6. Error Handling & Edge Cases

### Error Capture
```python
try:
    response = wrapped(*args, **kwargs)
except Exception as exception:
    span.record_exception(exception)
    status = Status(
        status_code=StatusCode.ERROR,
        description=f"{type(exception).__name__}: {exception}"
    )
    span.finish_tracing(status=status)
    raise
```

### Graceful Degradation
- All attribute extraction is wrapped in try/except
- Failures log warnings but don't break execution
- Invalid spans return `INVALID_SPAN` constant

### Edge Cases Handled
- Circular references in serialization
- Non-hashable types in attributes
- Missing or None values
- Streaming interruptions
- Response parsing failures

## 7. Configuration & Extensibility

### TraceConfig Options
```python
@dataclass
class TraceConfig:
    hide_llm_invocation_parameters: bool  # Hide model parameters
    hide_inputs: bool                     # Hide all inputs
    hide_outputs: bool                    # Hide all outputs
    hide_input_messages: bool            # Hide input messages only
    hide_output_messages: bool           # Hide output messages only
    hide_input_images: bool              # Hide images in inputs
    hide_input_text: bool                # Hide text in inputs
    hide_output_text: bool               # Hide text in outputs
    hide_embedding_vectors: bool         # Hide embedding vectors
    base64_image_max_length: int         # Truncate long base64 images
```

### Environment Variables
All config options can be set via environment:
- `OPENINFERENCE_HIDE_INPUTS=true`
- `OPENINFERENCE_BASE64_IMAGE_MAX_LENGTH=32000`

### Custom Attributes
```python
# Add custom attributes via context
with using_attributes(
    metadata={"experiment": "v2", "cohort": "A"},
    tags=["production", "high-priority"]
):
    ...

# Or directly on spans
span.set_attribute("custom.metric", 42)
```

### Provider Extensibility
- Auto-detects providers from base_url (OpenAI, Azure, Google)
- Supports custom `process_input` and `process_output` functions
- Works with any OpenTelemetry exporter

## 8. Export & Backend Integration

### OpenTelemetry Integration
The library builds on standard OpenTelemetry:
```python
# Use any OTEL exporter
from opentelemetry.exporter.otlp.proto.grpc import OTLPSpanExporter

exporter = OTLPSpanExporter(endpoint="localhost:4317")
tracer_provider.add_span_processor(
    BatchSpanProcessor(exporter)
)
```

### Span Limits
Default configuration for large payloads:
- Max span attributes: 10,000 (vs OTEL default 128)
- Respects environment overrides
- No built-in sampling (relies on OTEL)

### Performance Considerations
- Lazy attribute evaluation with callables
- Deferred attribute setting for important attributes
- Streaming accumulation to avoid memory issues
- Masking happens at attribute set time

### Batching Strategy
Uses OpenTelemetry's standard processors:
- `BatchSpanProcessor`: Batches spans before export
- `SimpleSpanProcessor`: Exports immediately (for debugging)
- Configurable via OTEL environment variables

## Key Implementation Patterns

### 1. Wrapper Pattern
All main components wrap OpenTelemetry objects:
- `OITracer` wraps `Tracer`
- `OpenInferenceSpan` wraps `Span`
- Allows intercepting and modifying behavior

### 2. Context Propagation
Uses OpenTelemetry's context system throughout:
- Thread-local storage for sync code
- Async context vars for async code
- Automatic parent-child relationships

### 3. Attribute Masking
Centralized masking in `TraceConfig.mask()`:
- Checks attribute keys against configuration
- Returns None to skip attributes
- Returns `__REDACTED__` for masked values

### 4. Lazy Evaluation
Supports callable attribute values:
```python
span.set_attribute("expensive", lambda: compute_expensive_value())
```

This comprehensive implementation provides a robust, extensible framework for tracing LLM applications while maintaining compatibility with the broader OpenTelemetry ecosystem.
