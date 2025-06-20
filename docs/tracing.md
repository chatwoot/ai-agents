# Ruby Agents SDK - Enhanced Tracing

Production-level tracing implementation that matches OpenAI Agents SDK standards, providing comprehensive observability for agents, tools, and handoffs.

## Overview

The Ruby Agents SDK includes a sophisticated tracing system designed to provide deep insights into multi-agent workflows. The tracing implementation offers:

- **Agent Execution Tracing**: Complete lifecycle tracking with clear agent identification
- **Tool Call Tracing**: Detailed parameter and result tracking with timing
- **Handoff Tracing**: Source/target agent details with context transfer tracking
- **Hierarchical Structure**: Parent-child relationships showing call stack depth
- **Structured Output**: Both human-readable console output and machine-readable JSON
- **Production Ready**: Thread-safe, configurable, with performance optimization

## Features

### 🤖 Agent Tracing
- Agent start/completion events with timing
- Clear agent identification and classification
- Input/output tracking with length metrics
- Error handling and exception tracking
- Hierarchical depth visualization

### 🔧 Tool Call Tracing
- Tool execution start/finish events
- Parameter sanitization (sensitive data protection)
- Result tracking with size metrics
- Performance timing per tool
- Error capture and reporting

### 🔄 Handoff Tracing
- Source and target agent identification
- Handoff reason and context tracking
- Multi-level handoff support
- Runner-level orchestration tracking
- Context transfer monitoring

### 📊 Output Formats
- **Color-coded console output** for development
- **Structured JSON logs** for production monitoring
- **Hierarchical visualization** with indentation
- **Timing information** with millisecond precision
- **Configurable verbosity** levels

## Configuration

### Basic Configuration

```ruby
# Enable enhanced tracing
Agents.configure_tracing({
  enhanced: true,
  structured_output: true,
  console_output: true,
  show_hierarchy: true,
  show_timing: true,
  show_details: true
})
```

### Production Configuration

```ruby
# Production-optimized settings
Agents.configure_tracing({
  enhanced: true,
  structured_output: true,
  console_output: false,           # Disable console for performance
  output_file: "/var/log/agents.jsonl",
  buffer_size: 1000,              # Larger buffer for efficiency
  flush_interval: 10.0,           # Longer flush interval
  max_trace_duration: 600,        # 10 minutes max trace time
  max_events_per_trace: 5000      # Higher event limit
})
```

### Development Configuration

```ruby
# Development with verbose output
Agents.configure_tracing({
  enhanced: true,
  console_output: true,
  show_hierarchy: true,
  show_timing: true,
  show_details: true,
  output_format: :structured
})
```

## Usage Examples

### Basic Agent Tracing

```ruby
class WeatherAgent < Agents::Agent
  name "Weather Specialist"
  uses WeatherTool
end

# Tracing is automatic
agent = WeatherAgent.new
result = agent.call("What's the weather in Tokyo?")
```

**Console Output:**
```
12:34:56.789 🤖 AGENT START Weather Specialist (33 chars)
12:34:57.123   🔧 TOOL CALL get_weather (location: Tokyo)
12:34:57.456   🔧 TOOL SUCCESS (27 chars) [667ms]
12:34:57.456 🤖 AGENT COMPLETE [667ms]
```

### Multi-Agent Handoffs

```ruby
class TriageAgent < Agents::Agent
  name "Triage Assistant"
  handoffs WeatherAgent
end

runner = Agents::Runner.new(initial_agent: TriageAgent, context: context)
result = runner.process("What's the weather in Paris?")
```

**Console Output:**
```
12:34:58.001   🤖 AGENT START Triage Assistant (32 chars)
12:34:58.334     🔧 TOOL CALL transfer_to_weather_specialist
12:34:58.334     🔄 HANDOFF Triage Assistant → Weather Specialist
12:34:58.335     🔄 HANDOFF COMPLETE [334ms]
12:34:58.335   🤖 AGENT COMPLETE [334ms]
```

### Complex Tool Workflows

```ruby
class GeneralAgent < Agents::Agent
  uses WeatherTool
  uses CalculatorTool
  uses TimeTool
end

agent = GeneralAgent.new
result = agent.call("What time is it, weather in NYC, and what's 15 * 25?")
```

**Console Output:**
```
12:35:00.001 🤖 AGENT START General Assistant (56 chars)
12:35:01.234   🔧 TOOL CALL get_time
12:35:01.256   🔧 TOOL SUCCESS (37 chars) [1.26s]
12:35:01.257   🔧 TOOL CALL get_weather (location: NYC)
12:35:01.389   🔧 TOOL SUCCESS (29 chars) [1.39s]
12:35:01.390   🔧 TOOL CALL calculator (expression: 15 * 25)
12:35:01.425   🔧 TOOL SUCCESS (13 chars) [1.42s]
12:35:01.425 🤖 AGENT COMPLETE [1.42s]
```

## JSON Structured Output

Every trace event also generates structured JSON for machine processing:

```json
{
  "timestamp": "2025-06-20T12:34:56.789Z",
  "event_type": "agent.start",
  "trace_id": "uuid-trace-id",
  "agent_class": "Weather Specialist",
  "agent_name": "Weather Specialist",
  "input_length": 33,
  "hierarchy": [{"type": "agenttrace", "id": "uuid", "name": "Weather Specialist"}],
  "depth": 0,
  "elapsed_time": 0.000123
}
```

```json
{
  "timestamp": "2025-06-20T12:34:57.123Z",
  "event_type": "tool.start",
  "trace_id": "tool-trace-id",
  "parent_trace_id": "parent-uuid",
  "tool_class": "WeatherTool",
  "tool_name": "get_weather",
  "method_name": "call",
  "params": {"location": "Tokyo"},
  "agent_context": "Weather Specialist",
  "depth": 1
}
```

## Event Types

### Agent Events
- `agent.start` - Agent execution begins
- `agent.complete` - Agent execution completes successfully
- `agent.error` - Agent execution fails with error

### Tool Events
- `tool.start` - Tool execution begins
- `tool.complete` - Tool execution completes successfully
- `tool.error` - Tool execution fails with error

### Handoff Events
- `handoff.start` - Handoff initiated
- `handoff.complete` - Handoff completed successfully
- `handoff.error` - Handoff failed

### LLM Events
- `llm.request.start` - LLM API request initiated
- `llm.request.complete` - LLM API request completed
- `llm.request.error` - LLM API request failed

### Guardrail Events
- `guardrails.input.start` - Input validation begins
- `guardrails.input.complete` - Input validation completes
- `guardrails.output.start` - Output validation begins
- `guardrails.output.complete` - Output validation completes

## Performance Considerations

### Buffer Management
- Events are buffered and flushed periodically for performance
- Buffer size and flush intervals are configurable
- Automatic flushing on buffer overflow

### Thread Safety
- All tracing operations are thread-safe
- Concurrent agent execution fully supported
- Lock-free event recording where possible

### Memory Management
- Automatic trace cleanup after completion
- Configurable maximum trace duration
- Event count limits to prevent memory leaks

### Sensitive Data Protection
- Automatic sanitization of sensitive parameters
- Configurable field filtering
- Truncation of large values

## Integration Examples

### With Monitoring Systems

```ruby
# Configure for Datadog
Agents.configure_tracing({
  enhanced: true,
  output_file: "/var/log/agents.jsonl",
  structured_output: true,
  console_output: false
})

# Log shipping via Fluentd/Filebeat to monitoring platform
```

### With Custom Processors

```ruby
# Custom trace processor
class CustomTraceProcessor
  def self.process_event(event)
    # Send to custom monitoring system
    MetricsCollector.record(event)
  end
end

# Register processor
Agents.tracer.add_processor(CustomTraceProcessor)
```

## Comparison with OpenAI SDK

| Feature | OpenAI Python SDK | Ruby Agents SDK |
|---------|------------------|-----------------|
| Agent Tracing | ✅ Basic | ✅ Enhanced with hierarchy |
| Tool Call Tracing | ✅ Standard | ✅ Detailed with sanitization |
| Handoff Tracing | ✅ Basic | ✅ Multi-level with context |
| Structured Output | ✅ JSON | ✅ JSON + Color console |
| Performance Optimized | ✅ Yes | ✅ Buffered + thread-safe |
| Custom Integrations | ✅ Limited | ✅ Extensible processors |
| Sensitive Data Protection | ❌ Manual | ✅ Automatic |
| Hierarchical Visualization | ❌ No | ✅ Full depth tracking |

## Best Practices

1. **Production Deployment**
   - Disable console output for performance
   - Use file-based logging with log rotation
   - Configure appropriate buffer sizes
   - Set reasonable trace duration limits

2. **Development**
   - Enable console output for immediate feedback
   - Use hierarchical visualization
   - Enable detailed timing information

3. **Monitoring**
   - Set up automated log ingestion
   - Create dashboards for key metrics
   - Configure alerting on error events

4. **Security**
   - Review sensitive data filtering
   - Secure log file access
   - Consider encryption for sensitive environments

## Troubleshooting

### Common Issues

1. **Missing trace events**
   - Ensure enhanced tracing is enabled
   - Check buffer flush settings
   - Verify output configuration

2. **Performance impact**
   - Disable console output in production
   - Increase buffer sizes
   - Reduce flush frequency

3. **Memory usage**
   - Set trace duration limits
   - Configure event count limits
   - Monitor trace cleanup

### Debug Mode

```ruby
# Enable debug mode for troubleshooting
Agents.configure_tracing({
  enhanced: true,
  console_output: true,
  show_details: true,
  buffer_size: 1  # Immediate flushing for debugging
})
```

## Future Enhancements

- OpenTelemetry integration
- Distributed tracing across services
- Performance profiling integration
- Custom span processors
- Real-time streaming to monitoring systems

---

The Ruby Agents SDK tracing system provides production-ready observability that matches and exceeds the capabilities of the OpenAI Python SDK, with additional features for Ruby-specific workflows and enterprise requirements.