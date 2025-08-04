# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.3] - 2025-08-04

### Fixed
- **Schema Parameter Passing**: Fixed issue where response schema parameters were not being properly passed through in agent conversations
  - Ensured schema configuration flows correctly through the agent execution pipeline
  - Improved parameter handling for structured output validation

## [0.4.2] - 2025-08-04

### Fixed
- **Structured Output Conversation History**: Fixed crash when restoring conversation history containing Hash content from structured output responses
  - Runner and MessageExtractor now properly handle Hash content without calling `.strip()` method
  - Added `MessageExtractor.content_empty?` utility method to handle both String and Hash content types

## [0.4.1] - 2025-08-04

### Fixed
- **Structured Output JSON Parsing**: Fixed automatic JSON parsing for structured output responses
  - Chat class now properly parses JSON string responses to Hash objects when schema is configured
  - Maintains compatibility with RubyLLM's automatic parsing behavior from the documentation
  - Gracefully handles invalid JSON by keeping original string content
  - Added comprehensive test coverage for both valid and invalid JSON scenarios

## [0.4.0] - 2025-08-01

### Added
- **Structured Output Support**: Agents can now enforce JSON schema validation for responses
  - Added `response_schema` parameter to `Agent#initialize` supporting both JSON Schema objects and `RubyLLM::Schema` classes
  - Automatic response validation ensures agents return data in predictable formats
  - Full support for complex nested schemas with objects, arrays, and validation constraints
  - Multi-agent systems can use different response schemas per agent
  - Comprehensive documentation with examples for data extraction and API integrations
- Updated to RubyLLM 1.5.0 with enhanced structured output capabilities
- New structured output documentation guide with practical examples

### Changed
- Enhanced `Chat` class to pass through `response_schema` configuration to underlying RubyLLM provider
- Improved agent cloning to preserve and override response schemas

## [0.3.0] - 2025-07-22

### Added
- Temperature control for agent responses
  - Added `temperature` parameter to `Agent#initialize` with default value of 0.7
  - Temperature controls randomness in LLM responses (0.0 = deterministic, 1.0 = very random)
  - Temperature is passed through to underlying Chat instance for model configuration
  - Agent cloning supports temperature overrides via `clone(temperature: value)`

## [0.2.2] - 2025-07-14

### Added
- Support for additional LLM providers:
  - DeepSeek (`deepseek_api_key`)
  - OpenRouter (`openrouter_api_key`)
  - Ollama (`ollama_api_base`)
  - AWS Bedrock (`bedrock_api_key`, `bedrock_secret_key`, `bedrock_region`, `bedrock_session_token`)
- OpenAI API base URL configuration (`openai_api_base`) for custom endpoints
- OpenAI organization and project ID configuration (`openai_organization_id`, `openai_project_id`)
- Updated `Configuration#configured?` method to check all supported providers

## [0.2.1] - 2025-07-08

### Fixed
- Fixed string role handling in conversation history restoration
  - `msg[:role]` is now converted to symbol before checking inclusion in restore_conversation_history
  - Prevents string roles like "user" from being skipped during history restoration

## [0.2.0] - 2025-07-08

### Added
- Real-time callback system for monitoring agent execution
  - `on_agent_thinking` callback for when agents are processing
  - `on_tool_start` callback for when tools begin execution
  - `on_tool_complete` callback for when tools finish execution
  - `on_agent_handoff` callback for when control transfers between agents
- Enhanced conversation history with complete tool call audit trail
  - Tool calls now captured in assistant messages with arguments
  - Tool result messages linked to original calls via `tool_call_id`
  - Full conversation replay capability for debugging
- CallbackManager for centralized event handling
- MessageExtractor service for clean conversation history processing

### Changed
- RunContext now includes callback management capabilities
- Improved thread safety for callback execution
- Enhanced error handling for callback failures (non-blocking)

## [0.1.3] - Previous Release

### Added
- Multi-agent orchestration with seamless handoffs
- Thread-safe agent execution architecture
- Tool integration system
- Shared context management
- Provider support for OpenAI, Anthropic, and Gemini
