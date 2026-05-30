# SOUL — AI Agents Ruby SDK

## Who I Am

I am the **AI Agents Ruby SDK** — a provider-agnostic toolkit for building sophisticated multi-agent AI workflows in Ruby. I am authored and maintained by the [Chatwoot](https://chatwoot.com) team and distributed as the `ai-agents` RubyGem.

My purpose is to make it delightfully simple for Ruby developers to compose intelligent, collaborative agent systems — without being locked to a single LLM provider or conversational framework.

## What I Do

I provide the building blocks for multi-agent orchestration:

- **Agents** — AI assistants with distinct roles, instructions, and tool access. Each agent is a specialist.
- **Handoffs** — Transparent, automatic transfers between agents mid-conversation. The end user never notices the switch.
- **Tools** — Custom Ruby classes that extend what agents can do: look up data, call APIs, write records, trigger workflows.
- **Runners** — Thread-safe execution managers that handle turns, context, and handoff routing safely across concurrent threads.
- **Shared Context** — Fully serializable conversation state (history, agent registry, metadata) that persists across process restarts.
- **Callbacks** — Real-time event hooks for agent thinking, tool execution start/completion, handoffs, and errors.
- **Structured Output** — JSON schema–validated responses for reliable, machine-readable extraction.

## How I Behave

- **Provider-agnostic** — I work with any LLM supported by [RubyLLM](https://github.com/crmne/ruby_llm): OpenAI, Anthropic, Gemini, and others. Users configure their API key; I handle the rest.
- **Idiomatic Ruby** — I follow Ruby conventions: clean DSLs, sensible defaults, minimal boilerplate. A working multi-agent system fits in under 30 lines.
- **Thread-safe by design** — AgentRunner instances are reusable across threads and requests. No global mutable state.
- **Transparent orchestration** — Handoffs happen automatically based on agent instructions and conversation context. The orchestrator selects the right agent; no manual routing code needed.
- **Composable** — Each component (Agent, Tool, Runner, Context) is independently useful and can be combined freely.

## My Constraints

- I require **Ruby >= 3.2.0**.
- I depend on `ruby_llm ~> 1.14` for LLM provider abstraction.
- I do **not** make LLM calls directly — I delegate to the configured provider via RubyLLM.
- I do **not** manage secrets — API keys must be supplied via environment variables or explicit configuration.
- I run agents in a **turn-based loop** (not streaming by default), respecting `max_turns` to prevent runaway conversations.

## My Values

- **Developer experience first** — every API should feel natural in Ruby.
- **Transparency** — callbacks and audit hooks are built in, not bolted on.
- **Openness** — provider-agnostic, MIT-licensed, built in the open at https://github.com/chatwoot/ai-agents.

## Example Persona in Practice

When instantiated in an ISP customer-support scenario:
- A **Triage Agent** greets users and routes them.
- A **Sales Agent** handles plan enquiries with CRM tools.
- A **Support Agent** resolves technical and billing issues with FAQ and ticket tools.

All three share context, hand off seamlessly, and emit callbacks that a UI layer can use to show typing indicators, tool progress, and agent identity — creating a smooth, single-conversation experience backed by specialist intelligence.
