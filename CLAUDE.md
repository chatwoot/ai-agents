# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Development Commands

### Testing
- `rake test` - Run all tests using Minitest
- `ruby -Ilib:test test/ruby/test_agents.rb` - Run specific test file

### Code Quality
- `rake rubocop` - Run RuboCop linter
- `rake` - Run both tests and RuboCop (default task)

### Development Setup
- `bundle install` - Install dependencies
- `bundle exec rake` - Run default tasks through Bundler

### Examples
- `ruby examples/booking/interactive.rb` - Run interactive airline booking demo
- `ruby examples/booking/automatic.rb` - Run automatic booking example

## Code Architecture

### Core Components

**Agents (`lib/agents/agent.rb`)**
- Base class for AI agents with Ruby DSL syntax
- Agents define `name`, `instructions`, `provider`, `model`, `uses` (tools), and `handoffs`
- Each agent is a specialized AI that can use tools and hand off to other agents
- Agents use RubyLLM for LLM integration and support multiple providers (OpenAI, Anthropic, Gemini)

**Runner (`lib/agents/runner.rb`)**
- Orchestrates multi-agent conversations with automatic handoffs
- Main entry point for users - handles conversation flow and agent switching
- Maintains conversation history and prevents infinite handoff loops
- Users call `runner.process(message)` and handoffs happen transparently

**Context (`lib/agents/context.rb`)**
- Shared state management between agents and tools
- Persists data across agent handoffs (e.g., customer info, booking details)
- Records agent transition history and metadata
- Can be subclassed for domain-specific context (e.g., `AirlineContext`)

**Tools (`lib/agents/tool.rb`)**
- Wrapper around RubyLLM::Tool with Ruby-like parameter syntax
- All tools are context-aware and receive execution context
- Define parameters with Ruby types (String, Integer, etc.)
- Tools implement `perform` method with keyword arguments

**Handoffs (`lib/agents/handoff.rb`)**
- Seamless agent-to-agent transfers using function calling
- Created dynamically at runtime based on agent's `handoffs` declaration
- Users never see handoffs happening - they get seamless responses

### Configuration
- `Agents.configure` block sets up API keys and defaults
- Supports multiple LLM providers through RubyLLM
- Configuration cascades from global defaults to agent-specific settings

### Example Pattern
The booking example (`examples/booking/`) demonstrates the typical pattern:
- `TriageAgent` - Routes customers to specialists, never answers directly
- `FaqAgent` - Handles general airline questions using FAQ lookup
- `SeatBookingAgent` - Manages seat changes and updates
- All agents can hand off back to triage if they can't handle a request

### Ruby Gem Structure
- `lib/agents.rb` - Main entry point and configuration
- `lib/agents/` - Core component classes
- `ruby-agents.gemspec` - Gem specification, depends on `ruby_llm`
- `sig/` - RBS type signatures for static analysis

## Important Notes

- This is a Ruby gem project, not a Rails application
- Uses RubyLLM as the core LLM integration library
- Follows Ruby gem conventions with `lib/`, `test/`, and `examples/` directories
- No custom configuration files (.cursor, .github/copilot-instructions.md) found
- Uses Minitest for testing, RuboCop for linting
- Main use case is multi-agent AI workflows with transparent handoffs