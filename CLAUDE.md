# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a Ruby AI Agents SDK that provides multi-agent orchestration capabilities, similar to OpenAI's Agents SDK but built for Ruby. The SDK enables the creation of sophisticated AI workflows with specialized agents, tool execution, conversation handoffs, MCP (Model Context Protocol) integration, and comprehensive tracing/observability.

**IMPORTANT**: This is a generic agent library. When implementing library code, ensure that:
- No domain-specific logic from examples (airline booking, FAQ, ISP support, etc.) leaks into the core library
- The library remains agnostic to specific use cases
- All domain-specific implementations belong in the examples directory only

## Development Commands

### Building and Testing
```bash
# Install dependencies
bundle install

# Run tests with RSpec
rake spec
# OR
bundle exec rspec

# Run specific spec file
bundle exec rspec spec/agents/agent_spec.rb

# Run tests with coverage report
bundle exec rspec  # SimpleCov will generate coverage/index.html

# Lint code (includes RSpec cops)
rake rubocop
# OR
bundle exec rubocop

# Auto-fix linting issues
bundle exec rubocop -a

# Run all checks (spec + lint)
rake
```

### Interactive Development
```bash
# Start interactive console
bin/console

# Run ISP customer support demo (current main example)
ruby examples/isp-support/interactive.rb

# Run MCP integration examples
ruby examples/mcp/filesystem_example.rb
ruby examples/mcp/http_client_example.rb
ruby examples/mcp/linear_example.rb
ruby examples/mcp/multi_agent_workflow.rb

# Run tracing examples with OpenTelemetry
ruby examples/tracing/basic_example.rb
ruby examples/tracing/mintlify_workflow_tracing_example.rb
```

## Architecture and Code Structure

### Core Components (Generic Library)

**lib/agents.rb** - Main module and configuration entry point. Configures both the Agents SDK and underlying RubyLLM library. Key features:
- Global configuration for API keys, models, timeouts, debug settings
- Tracing configuration with OpenTelemetry support and environment variable overrides
- Automatic RubyLLM configuration delegation
- Default model is `gpt-4o-mini`

**lib/agents/agent.rb** - The core `Agent` class for defining AI agents with thread-safe, immutable design:
- Instance-based configuration: `name`, `instructions`, `model`, `tools`, `handoff_agents`
- Instructions can be static strings or dynamic Procs for context-based customization
- Thread-safe handoff registration and MCP client management using mutexes
- Immutable cloning with `clone(**changes)` for runtime specialization
- MCP client integration with automatic tool loading and collision detection
- **No domain-specific logic** - remains completely generic

**lib/agents/runner.rb** - Execution engine that orchestrates multi-agent conversations:
- Turn-based execution model with comprehensive tracing
- Automatic handoff detection via context signaling
- Thread-safe conversation history management
- Comprehensive OpenTelemetry instrumentation for observability
- Error handling with graceful degradation
- Maximum turn limits to prevent infinite loops

**lib/agents/tool.rb** - Thread-safe base class for agent tools. Inherits from `RubyLLM::Tool` and adds:
- Enhanced parameter definitions with Ruby type conversion to JSON schema
- Thread-safe execution through `ToolContext` parameter injection
- Comprehensive tracing with execution timing and error tracking
- Functional tool creation via `Tool.tool()` class method
- **Domain-agnostic** - specific tool implementations belong in user code

**lib/agents/handoff.rb** - Contains the handoff system classes:
- `HandoffResult` - Represents a handoff decision with target agent and reason
- `HandoffTool` - Dynamically generated tools for agent-to-agent transfers
- Context-based signaling mechanism (no text parsing required)
- **Generic handoff mechanism** - no assumptions about specific agent types

**lib/agents/run_context.rb** & **lib/agents/tool_context.rb** - Context management system:
- `RunContext` - Wraps shared state and usage tracking for conversations
- `ToolContext` - Provides tools access to context and execution metadata
- Thread-safe state sharing between agents and tools

**lib/agents/tracing.rb** - Comprehensive observability system:
- OpenTelemetry-compatible tracing with configurable exporters
- Support for Jaeger, file export, and console output
- Detailed instrumentation of conversations, tool calls, and handoffs
- Configurable sensitive data inclusion/exclusion
- Cost estimation and performance tracking

**lib/agents/mcp/** - Model Context Protocol integration:
- `Client` - Connects to MCP servers via stdio or HTTP transport
- `Tool` - Wraps MCP tools as Agents SDK tools
- Transport abstraction supporting stdio and HTTP protocols
- Automatic tool discovery and registration

### Key Design Patterns

#### Agent Definition Pattern (Instance-Based)
```ruby
# Create agents as instances (recommended approach)
agent = Agents::Agent.new(
  name: "Customer Service Agent",
  instructions: "You are a helpful customer service agent",
  model: "gpt-4o",  # Optional, defaults to gpt-4o-mini
  tools: [email_tool, ticket_tool],
  handoff_agents: [billing_agent, support_agent]
)

# Dynamic instructions based on context
context_aware_agent = Agents::Agent.new(
  name: "Personal Assistant",
  instructions: ->(context) {
    user = context.context[:user]
    "You are helping #{user[:name]}, a #{user[:tier]} customer"
  },
  tools: [calendar_tool, email_tool]
)

# Register handoffs after creation (clean separation)
triage.register_handoffs(billing, support, sales)
billing.register_handoffs(triage)  # Hub-and-spoke pattern
```

#### Tool Definition Pattern (Thread-Safe)
```ruby
# Class-based tool definition
class MyTool < Agents::Tool
  name "my_tool"
  description "What this tool does"
  param :input_param, String, "Parameter description"
  param :optional_param, Integer, "Optional param", required: false

  def perform(tool_context, input_param:, optional_param: nil)
    # Access shared state through tool_context - NEVER use instance variables!
    api_key = tool_context.context[:api_key]
    user_id = tool_context.context[:user_id]
    
    # All state comes from parameters - ensures thread safety
    "Tool result: #{input_param}"
  end
end

# Functional tool definition (for simple tools)
calculator = Agents::Tool.tool("calculate", description: "Perform math") do |tool_context, expression:|
  begin
    result = eval(expression)  # Don't actually use eval in production!
    result.to_s
  rescue => e
    "Error: #{e.message}"
  end
end
```

#### Context-Based Handoff System
The handoff system uses context signaling rather than text parsing:
1. `HandoffTool` instances are created dynamically from `handoff_agents` declarations
2. When called, `HandoffTool.perform` sets `context[:pending_handoff]` 
3. `Runner` detects pending handoffs after each LLM response
4. Automatic agent switching with conversation history preservation

#### Execution Flow with Runner
```ruby
# Simple execution
result = Agents::Runner.run(agent, "Hello, help me with billing")
puts result.output

# With context and handoffs
context = { user_id: 123, subscription_tier: "premium" }
result = Agents::Runner.run(triage_agent, "I can't pay my bill", context: context)
# Triage agent automatically hands off to billing agent
# User gets response from billing agent without knowing about handoff
```

#### MCP Integration
```ruby
# Connect to MCP servers
filesystem_client = Agents::MCP::Client.new(
  name: "filesystem",
  command: "npx",
  args: ["@modelcontextprotocol/server-filesystem", "/tmp"]
)

# Add MCP tools to an agent
agent.add_mcp_clients(filesystem_client)
# Agent now has access to filesystem operations through MCP tools
```

### Configuration Rules

#### Class Naming
- Use flat naming like `class Agents::Tool` instead of nested declarations
- Follow Ruby naming conventions for agent and tool classes

#### Documentation
- Always write doc strings when writing functions
- Use YARD format for documentation
- Always write RDoc for new methods
- When creating a new file, start the file with a description comment on what the file has and where does it fit in the project

#### Model Defaults
- Default model is `gpt-4o-mini` (configured in lib/agents.rb)
- Can be overridden per agent or via global configuration
- Examples typically use `gpt-4o` for better performance

#### Environment Variables
```bash
# Tracing configuration
AGENTS_ENABLE_TRACING=true           # Enable tracing globally
AGENTS_EXPORT_PATH=./traces          # Trace export directory
AGENTS_INCLUDE_SENSITIVE_DATA=false  # Include sensitive data in traces
AGENTS_SERVICE_NAME=my-agents        # Service name for tracing
AGENTS_CONSOLE_OUTPUT=true           # Enable console trace output
JAEGER_ENDPOINT=http://localhost:14268/api/traces  # Jaeger endpoint

# Debug mode for RubyLLM
RUBYLLM_DEBUG=true                   # Enable detailed LLM debugging
```

### Examples Structure

**examples/isp-support/** - Complete ISP customer support demo showcasing:
- Hub-and-spoke handoff pattern with triage agent
- Specialized agents (customer info, sales, support)
- Context sharing for customer data
- Real-world tool implementations (CRM lookup, lead creation, etc.)

**examples/mcp/** - Model Context Protocol integration examples:
- Filesystem server integration
- HTTP client/server examples  
- Linear API integration
- Multi-agent workflows with MCP tools
- Tool filtering and customization

**examples/tracing/** - Observability and tracing examples:
- Basic tracing setup with OpenTelemetry
- Jaeger integration for distributed tracing
- Performance monitoring and cost tracking
- Docker Compose setup for local tracing infrastructure

Note: All examples are purely demonstrative. The SDK is not limited to or designed specifically for any particular domain.

### Dependencies and Integration

**RubyLLM Integration** - Built on top of RubyLLM library for LLM communication:
- Agents SDK configures RubyLLM automatically via `Agents.configure`
- Tools inherit from `RubyLLM::Tool` but use enhanced `perform` method
- Conversation history restored using `chat.add_message`
- Debug mode available via `ENV["RUBYLLM_DEBUG"] = "true"`

**Provider Support** - Currently supports OpenAI through RubyLLM, extensible to other providers

### Important Implementation Details

1. **Thread Safety**: Agents are immutable instances that can be safely shared across threads. All execution state is passed through parameters, never stored in instance variables.

2. **Tool Context Flow**: `Runner.run()` → `RubyLLM.chat()` → `ToolWrapper.execute()` → `Tool.execute(tool_context, **params)` → `Tool.perform(tool_context, **params)` - context injection ensures thread safety.

3. **Handoff Detection**: Uses context-based signaling (`context[:pending_handoff]`) rather than parsing LLM responses. The Runner checks for pending handoffs after each turn.

4. **Conversation Management**: The Runner automatically manages conversation history in the context, preserving state across handoffs using `chat.add_message()`.

5. **Model Configuration**: Default model is `gpt-4o-mini` but examples use `gpt-4o` for better performance. Configurable per agent and globally.

6. **Tracing Integration**: Comprehensive OpenTelemetry instrumentation throughout the execution flow provides detailed observability of conversations, tool calls, handoffs, and performance metrics.

7. **MCP Integration**: Agents can dynamically load tools from MCP servers, enabling integration with external systems and services through standardized protocols.

8. **Library vs Example Code**: The core library (lib/agents/*) must remain completely generic and free of domain-specific logic. All domain-specific implementations belong exclusively in the examples directory.

### Testing Guidelines

When writing tests, follow these rules: 
1. Avoid stubbing using `allow_any_instance_of` - use dependency injection instead
2. Each example block `it ... end` should have less than 20 lines
3. Example groups should not have more than 10 memoized helpers or expect statements
4. Never use `receive_message_chain` - prefer explicit method stubs
5. Always use verifying doubles instead of normal doubles for external dependencies
6. Test thread safety by running specs with multiple threads when testing concurrent behavior
7. Use `Agents::Runner.run` in integration tests rather than testing internal methods directly

### Configuration Examples

```ruby
# Basic configuration
Agents.configure do |config|
  config.openai_api_key = ENV['OPENAI_API_KEY']
  config.default_model = 'gpt-4o'
  config.debug = true
  
  # Enable tracing
  config.enable_tracing!
  config.tracing.service_name = 'my-agents-app'
  config.tracing.include_sensitive_data = false
  config.tracing.jaeger_endpoint = 'http://localhost:14268/api/traces'
end

# Multi-provider configuration
Agents.configure do |config|
  config.openai_api_key = ENV['OPENAI_API_KEY']
  config.anthropic_api_key = ENV['ANTHROPIC_API_KEY'] 
  config.gemini_api_key = ENV['GEMINI_API_KEY']
  config.default_model = 'gpt-4o-mini'
  config.request_timeout = 300
end
```