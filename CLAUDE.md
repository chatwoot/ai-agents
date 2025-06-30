# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Purpose

This project is a Ruby SDK for building multi-agent AI workflows. It allows developers to create specialized AI agents that can collaborate to solve complex tasks. The key features include:

-   **Multi-Agent Orchestration**: Defining and managing multiple AI agents with distinct roles.
-   **Seamless Handoffs**: Transferring conversations between agents without the user's knowledge.
-   **Tool Integration**: Allowing agents to use custom tools to interact with external systems.
-   **Shared Context**: Maintaining state and conversation history across agent interactions.
-   **Provider Agnostic**: Supporting various LLM providers like OpenAI, Anthropic, and Gemini.

## Key Technologies

-   **Ruby**: The primary programming language.
-   **RubyLLM**: The underlying library for interacting with Large Language Models.
-   **RSpec**: The testing framework.
-   **RuboCop**: The code style linter.
-   **GitHub Actions**: For continuous integration (testing and linting).

## Project Structure

-   `lib/`: The core source code of the `ai-agents` gem.
    -   `lib/agents.rb`: The main entry point, handling configuration and loading other components.
    -   `lib/agents/agent.rb`: Defines the `Agent` class, which represents an individual AI agent.
    -   `lib/agents/tool.rb`: Defines the `Tool` class, the base for creating custom tools for agents.
    -   `lib/agents/runner.rb`: Orchestrates the multi-agent conversations and handoffs.
-   `spec/`: Contains the RSpec tests for the project.
-   `examples/`: Includes example implementations of multi-agent systems, such as an ISP customer support demo.
-   `Gemfile`: Manages the project's Ruby dependencies.
-   `.rubocop.yml`: Configures the code style rules for RuboCop.
-   `.github/workflows/main.yml`: Defines the CI pipeline for running tests and linting on push and pull requests.

## Development Workflow

1.  **Dependencies**: Managed by Bundler (`bundle install`).
2.  **Testing**: Run tests with `bundle exec rspec`.
3.  **Linting**: Check code style with `bundle exec rubocop`.
4.  **CI/CD**: GitHub Actions automatically runs tests and linting for all pushes and pull requests to the `main` branch.

## How to Run the Example

The project includes an interactive example of an ISP customer support system. To run it:

```bash
ruby examples/isp-support/interactive.rb
```

This will start a command-line interface where you can interact with the multi-agent system.

## Key Concepts

-   **Agent**: An AI assistant with a specific role, instructions, and tools.
-   **Tool**: A custom function that an agent can use to perform actions (e.g., look up customer data, send an email).
-   **Handoff**: The process of transferring a conversation from one agent to another. This is a core feature of the SDK.
-   **Runner**: The component that manages the conversation flow, including executing agent logic and handling handoffs.
-   **Context**: A shared state object that stores information throughout the conversation, such as conversation history and user data.

## Development Commands

### Testing
```bash
# Run all tests with RSpec
bundle exec rspec

# Run tests with coverage report (uses SimpleCov)
bundle exec rake spec

# Run specific test file
bundle exec rspec spec/agents/agent_spec.rb

# Run specific test with line number
bundle exec rspec spec/agents/agent_spec.rb:25
```

### Code Quality
```bash
# Run RuboCop linter
bundle exec rubocop

# Run RuboCop with auto-correction
bundle exec rubocop -a

# Run both tests and linting (default rake task)
bundle exec rake
```

### Development
```bash
# Install dependencies
bundle install

# Interactive Ruby console with gem loaded
bundle exec irb -r ./lib/agents

# Run ISP support example interactively
ruby examples/isp-support/interactive.rb
```

## Architecture

### Core Components

- **Agents::Agent**: Individual AI agents with specific roles, instructions, and tools
- **Agents::Runner**: Orchestrates multi-agent conversations with automatic handoffs
- **Agents::Tool**: Base class for custom tools that agents can execute
- **Agents::Context**: Shared state management across agent interactions
- **Agents::Handoff**: Manages seamless transfers between agents

### Key Design Principles

1. **Thread Safety**: All components are designed to be thread-safe. Tools receive context as parameters, not instance variables.

2. **Immutable Agents**: Agents are configured once and can be cloned with modifications. No execution state is stored in agent instances.

3. **Provider Agnostic**: Built on RubyLLM, supports OpenAI, Anthropic, and Gemini through configuration.


### File Structure

```
lib/agents/
├── agent.rb          # Core agent definition and configuration
├── runner.rb         # Execution engine for multi-agent workflows
├── tool.rb           # Base class for custom tools
├── handoff.rb        # Agent handoff management
├── chat.rb           # Chat message handling
├── result.rb         # Result object for agent responses
├── run_context.rb    # Execution context management
├── tool_context.rb   # Tool execution context
├── tool_wrapper.rb   # Thread-safe tool wrapping
└── version.rb        # Gem version
```

### Configuration

The SDK requires at least one LLM provider API key:

```ruby
Agents.configure do |config|
  config.openai_api_key = ENV['OPENAI_API_KEY']
  config.anthropic_api_key = ENV['ANTHROPIC_API_KEY']
  config.gemini_api_key = ENV['GEMINI_API_KEY']
  config.default_model = 'gpt-4o-mini'
  config.debug = true
end
```

### Tool Development

When creating custom tools:
- Extend `Agents::Tool`
- Use `tool_context` parameter for all state
- Never store execution state in instance variables
- Follow the thread-safe design pattern shown in examples

### Testing Strategy

- SimpleCov tracks coverage with 50% minimum overall, 40% per file
- WebMock is used for HTTP mocking in tests
- RSpec is the testing framework with standard configuration
- Tests are organized by component in `spec/agents/`

### Examples

The `examples/` directory contains complete working examples:
- `isp-support/`: Multi-agent ISP customer support system
- Shows hub-and-spoke architecture patterns
- Demonstrates tool integration and handoff workflows
