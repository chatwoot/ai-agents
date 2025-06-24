# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a Ruby AI Agents SDK that provides multi-agent orchestration capabilities, similar to OpenAI's Agents SDK but built for Ruby. The SDK enables the creation of sophisticated AI workflows with specialized agents, tool execution, and conversation handoffs.

**IMPORTANT**: This is a generic agent library. When implementing library code, ensure that:
- No domain-specific logic from examples (airline booking, FAQ, seat management, etc.) leaks into the core library
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

# Run the airline booking demo
ruby examples/booking/interactive.rb

# Run automatic booking demo
ruby examples/booking/automatic.rb
```

## Architecture and Code Structure

### Core Components (Generic Library)

**lib/agents.rb** - Main module and configuration entry point. Configures both the Agents SDK and underlying RubyLLM library. Contains the `RECOMMENDED_HANDOFF_PROMPT_PREFIX` for multi-agent workflows.

**lib/agents/agent.rb** - The core `Agent` class with Ruby-like DSL for defining AI agents. Key features:
- Class-level configuration: `name`, `instructions`, `provider`, `model`, `uses`, `handoffs`
- Instance execution via `call` method with conversation history management
- Tool and handoff tool registration at runtime
- Context-aware execution with proper conversation history restoration using `chat.add_message`
- **No domain-specific logic** - remains completely generic

**lib/agents/tool.rb** - Base class for tools that agents can use. Inherits from `RubyLLM::Tool` and adds:
- Ruby-style parameter definitions with automatic JSON schema conversion
- Context injection through `perform` method (called by `execute`)
- Enhanced parameter definition supporting Ruby types (String, Integer, etc.)
- **Domain-agnostic** - specific tool implementations belong in user code

**lib/agents/handoff.rb** - Contains the handoff system classes:
- `HandoffResult` - Represents a handoff decision
- `AgentResponse` - Wraps agent responses with optional handoff results
- `HandoffTool` - Generic tool for transferring between agents using context-based signaling
- **Generic handoff mechanism** - no assumptions about specific agent types

**lib/agents/context.rb** - Base context class for sharing state between agents and tools across handoffs. Must be subclassed for domain-specific context. The base class provides only generic state management capabilities.

**lib/agents/runner.rb** - Execution engine for orchestrating multi-agent workflows (future implementation).

### Key Design Patterns

#### Agent Definition Pattern (Generic)
```ruby
class MyAgent < Agents::Agent
  name "Agent Name"
  instructions "Behavior description" # Can be dynamic via Proc
  provider :openai  # Optional, defaults to configured provider
  model "gpt-4o"    # Optional, defaults to configured model

  uses SomeTool     # Register tools by class
  handoffs OtherAgent, AnotherAgent  # Define possible handoff targets
end
```

#### Tool Definition Pattern (Generic)
```ruby
class MyTool < Agents::Tool
  description "What this tool does"
  param :input_param, String, "Parameter description"
  param :optional_param, Integer, "Optional param", required: false

  def perform(input_param:, optional_param: nil, context:)
    # context is always available for state management
    # Must implement perform, not execute
    # Tool logic should be domain-specific in user implementations
    "Tool result"
  end
end
```

#### Context-Based Handoff System
The handoff system uses context signaling rather than text parsing:
1. `HandoffTool` instances are created automatically from `handoffs` declarations
2. When called, `HandoffTool.perform` sets `context[:pending_handoff]`
3. `Agent.detect_handoff_from_context` checks for pending handoffs after LLM responses
4. Interactive systems handle handoffs by switching to the target agent class

#### Conversation History Management
Critical for multi-turn conversations:
- Agents maintain `@conversation_history` as array of `{user:, assistant:, timestamp:}` hashes
- `restore_conversation_history(chat)` uses `chat.add_message(role:, content:)` to restore RubyLLM chat state
- This prevents agents from "forgetting" previous conversation turns

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
- Default model for OpenAI provider is `gpt-4.1-mini` (configured in lib/agents.rb)
- Can be overridden in agent classes or runtime configuration

### Examples Structure

**examples/booking/** - Complete airline booking demo showcasing multi-agent workflows. This is just one example of how the SDK can be used. The example demonstrates:
- Multi-agent workflow patterns
- Context sharing between agents
- Tool usage patterns
- Interactive CLI and automatic execution modes
- Proper handoff handling

Note: The airline booking scenario is purely demonstrative. The SDK is not limited to or designed specifically for airline systems.

### Dependencies and Integration

**RubyLLM Integration** - Built on top of RubyLLM library for LLM communication:
- Agents SDK configures RubyLLM automatically via `Agents.configure`
- Tools inherit from `RubyLLM::Tool` but use enhanced `perform` method
- Conversation history restored using `chat.add_message`
- Debug mode available via `ENV["RUBYLLM_DEBUG"] = "true"`

**Provider Support** - Currently supports OpenAI through RubyLLM, extensible to other providers

### Important Implementation Details

1. **Conversation History**: Must call `restore_conversation_history(chat)` before each agent execution to maintain conversation state across turns.

2. **Tool Context Flow**: `RubyLLM.execute()` → `Agents::Tool.execute()` → `Tool.perform(context:, **args)` - the context injection happens in the base `Tool.execute` method.

3. **Handoff Detection**: Uses context-based detection (`@context[:pending_handoff]`) rather than parsing LLM responses for tool calls.

4. **Model Configuration**: Default model is `gpt-4.1-mini` but examples use `gpt-4o` for better performance.

5. **Thread Safety**: Agents are designed to be stateless with context passed through execution rather than stored in instance variables.

6. **Library vs Example Code**: The core library (lib/agents/*) must remain completely generic and free of domain-specific logic. All domain-specific implementations (airline booking, FAQ systems, etc.) belong exclusively in the examples directory.

### Testing Guidelines

When writing tests, follow the rules: 
1. Avoid stubbing using allow_any_instance_of`
2. Each example block `it ... end` should have less than 20 lines
3. Example group should not have more than 10 memoized helpers, not more than 10 except statements
4. Never use `receive_message_chain`
5. When writing tests, always use verifying doubles and never normal doubles
```