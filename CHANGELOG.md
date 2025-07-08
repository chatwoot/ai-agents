# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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