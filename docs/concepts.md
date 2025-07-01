---
layout: default
title: Concepts
nav_order: 2
has_children: true
---

# Concepts

This section covers the core concepts of the AI Agents library. Understanding these concepts is essential for building robust and scalable AI agent systems.

## Overview

The AI Agents library is built around several key concepts that work together to provide a powerful framework for multi-agent AI workflows:

- **[Agents](concepts/agents.html)** - Immutable, thread-safe AI assistants with specific roles and capabilities
- **[AgentRunner](concepts/runner.html)** - Thread-safe execution manager for multi-agent conversations
- **[Context](concepts/context.html)** - Serializable state management that persists across agent interactions
- **[Handoffs](concepts/handoffs.html)** - Tool-based mechanism for seamless agent transitions
- **[Tools](concepts/tools.html)** - Stateless extensions for external system integration

## Architecture Principles

The library follows these core design principles:

- **Immutability**: Agents are immutable once created, preventing runtime configuration changes
- **Thread Safety**: All components support concurrent execution without state corruption
- **Provider Agnostic**: Built on RubyLLM for unified access to OpenAI, Anthropic, and Gemini
- **Conversation Continuity**: Context serialization enables persistence across process boundaries
- **Separation of Concerns**: Clear boundaries between agent definition, execution, and state management