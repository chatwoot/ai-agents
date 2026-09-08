# RubyLLM v2 migration assessment

Assessment date: September 8, 2026.

There is substantial scope to slim ai-agents down. The recommended direction is to make it primarily responsible for **handoff policy, agent identity, and shared application state**, with RubyLLM owning more of the execution, message handling, and accounting.

This assessment covers the original implementation, the intervening release notes, and the v2 release candidate's source. Implementation progress and verification are recorded below.

## Baseline version and release path

We currently have **RubyLLM 1.14.0** in [Gemfile.lock](Gemfile.lock). Our [gemspec](ai-agents.gemspec) allows newer 1.x releases through `~> 1.14`, but excludes v2. **2.0.0.rc1 was published on September 8, 2026.** [Release](https://github.com/crmne/ruby_llm/releases/tag/v2.0.0.rc1)

| Release | What matters for ai-agents |
|---|---|
| [1.14.1](https://github.com/crmne/ruby_llm/releases/tag/1.14.1) | Provider metadata cleanup and attachment fixes. Little direct code-removal opportunity for us. |
| [1.15.0](https://github.com/crmne/ruby_llm/releases/tag/1.15.0) | Native token/cost objects, additive callbacks, and tool parameter inference. Starts replacing accounting and callback glue. |
| [1.16.0](https://github.com/crmne/ruby_llm/releases/tag/1.16.0) | Native instrumentation for model requests and tools; optional concurrent tool execution. Makes our tracing machinery a strong simplification candidate. |
| [2.0.0.rc1](https://github.com/crmne/ruby_llm/releases/tag/v2.0.0.rc1) | Explicit execution steps, approvals, cancellation, fallbacks, richer messages, accounting for individual attempts, and workflow tracing. Removes several APIs we currently depend on. |

**RubyLLM's agent abstraction already existed in our 1.14 baseline.** Moving agent configuration upstream is an existing opportunity that v2 expands. [1.14 agent source](https://github.com/crmne/ruby_llm/blob/1.14.0/lib/ruby_llm/agent.rb)

## Delegation opportunities

The scope below is ordered roughly by value.

| Our responsibility | Proposed direction | What remains ours |
|---|---|---|
| Execution in [Runner](lib/agents/runner.rb) | Drive RubyLLM's `step`/`generate`/`run_tools` APIs. Replace the halt-dependent handoff mechanism. | Allowed targets, switching agents, execution limits, and continuation policy. |
| Accounting in [RunContext::Usage](lib/agents/run_context.rb) | Use native tokens, costs, and usage events. | A small aggregation boundary for one ai-agents run, including nested agents. |
| [TracingCallbacks](lib/agents/instrumentation/tracing_callbacks.rb) | Build spans from native instrumentation events and workflow correlation. | Langfuse attribute mapping, session metadata, and agent/handoff annotations. |
| History reconstruction and [MessageExtractor](lib/agents/helpers/message_extractor.rb) | Use RubyLLM message serialization and public history import APIs. | Our `agent_name` attribution and compatibility with previously stored history. |
| Configuration in [agents.rb](lib/agents.rb) and [Agent](lib/agents/agent.rb) | Delegate provider configuration directly; progressively accept native RubyLLM agents or configured chats. | Agent names, handoff relationships, and any retained compatibility API. |
| [ToolWrapper](lib/agents/tool_wrapper.rb) and [AgentTool](lib/agents/agent_tool.rb) | Reduce them to adapters around native tools and agent execution. | Context injection, child-agent isolation, handoff restrictions, and output extraction. |

### Execution limits and accounting

Execution limits can become meaningful at the actual model-call boundary. Today our `max_turns` counts outer runner iterations, while `chat.ask` or `chat.complete` can execute several model/tool rounds internally. Likewise, our usage tracker sees the returned response rather than every intermediate generation. Explicit stepping and native accounting address both limitations. [Execution controls](https://rubyllm.com/next/agentic-workflows/), [usage accounting](https://rubyllm.com/next/cost-and-usage-tracking/)

### History serialization

History serialization is a bigger opportunity than merely shortening code. Our extractor preserves a small subset of message fields. V2's native message format includes attachments, thinking signatures, citations, server-tool calls, and native reasoning content. Building on its `Message#to_h` and import support would reduce the fields we must maintain ourselves.

We still need an adapter for existing stored histories; message serialization alone does not preserve the entire usage ledger or approval state. [Message source](https://github.com/crmne/ruby_llm/blob/v2.0.0.rc1/lib/ruby_llm/message.rb), [chat source](https://github.com/crmne/ruby_llm/blob/v2.0.0.rc1/lib/ruby_llm/chat.rb)

### Instrumentation

Instrumentation can become an adapter rather than an execution-tracking subsystem. Native events provide actual operation boundaries, inputs, results, errors, and usage. Workflow/step identifiers can carry the execution hierarchy. RubyLLM still needs an adapter to emit our OpenTelemetry/Langfuse representation. [Instrumentation](https://rubyllm.com/next/instrumentation/)

## Boundaries that remain in ai-agents

- **Handoff orchestration remains ours.** RubyLLM documents handoffs as caller-written Ruby. Its `workflow` API adds observability, not an orchestration engine. [Handoffs](https://rubyllm.com/next/agentic-workflows/#agent-handoffs)
- **Shared state remains ours.** `RubyLLM::Context` isolates provider configuration; it does not replace our application state or `ToolContext`. [Context source](https://github.com/crmne/ruby_llm/blob/v2.0.0.rc1/lib/ruby_llm/context.rb)
- **Agent switching still needs explicit configuration handling.** In rc1, wrapping an existing plain chat with another native agent adds tools and does not automatically apply that agent's model. We cannot simply delete our switching logic. [Agent source](https://github.com/crmne/ruby_llm/blob/v2.0.0.rc1/lib/ruby_llm/agent.rb)
- **Callbacks have different behavior.** Ours isolate callback failures. Native callbacks propagate exceptions. Also, our tracing hook is registered again after every handoff, so mechanically replacing it with an additive callback would duplicate spans.

## Required v2 compatibility work

- `halt`/`Tool::Halt` disappear.
- `RubyLLM::Content` disappears; attachments become separate message fields.
- Structured output moves from a Hash in `content` to `parsed`.
- Tool invocation becomes keyword-based; tool DSL and metadata methods are renamed.
- Legacy callbacks, token readers, `with_params`, and configuration replacement options change.
- OpenAI defaults to Responses, and explicit temperatures are sent unchanged. Our default `temperature: 0.7` therefore needs attention for models that reject it.

The [upgrade guide](https://rubyllm.com/next/upgrading/) documents these changes.

## Recommended scope

Implementation progress:

- Provider configuration now delegates directly to RubyLLM. `Agents.configure` and
  `Agents.configuration` share `RubyLLM.config`; the duplicate `Agents::Configuration`
  class and its `configured?` helper are removed. Use `config.log_level = :debug`
  instead of `config.debug = true`. Defaults now come from RubyLLM.
- The dependency is now pinned to `2.0.0.rc1`. Schematist replaces ruby_llm-schema;
  tools use `parameter`/`description`, and native callbacks use `after_message`.
- Runner uses `generate` and `run_tools`. `max_turns` now limits actual generations,
  including handoffs, and usage includes intermediate model responses. Handoffs
  finish the current tool round before switching and explicitly clear old settings.
- Structured results read `response.parsed`; the default temperature is now `nil`.
  `RunResult#chat` exposes the native chat, including pending approval inspection.
  Agent tools report unsupported nested approvals explicitly.
- The offline suite passes against rc1. Existing OpenAI fixtures explicitly select
  Chat Completions; production configuration retains RubyLLM's Responses default.
- History now uses native `Message#to_h`, retaining provider fields and adding only
  agent attribution. Legacy array-shaped tool calls, structured content, and image
  content blocks are normalized on import. JSON context round trips are supported.
  Emitted `result.messages` tool calls are now an ID-keyed Hash, not an Array.
  Durable attachment history requires durable URL/path sources; IO and ActiveStorage
  objects still need application-managed persistence. Approval decisions are not
  part of message serialization.

1. **V2 execution compatibility:** stepping, handoffs, tool contracts, structured results, and explicit configuration switching.
2. **Remove duplicated infrastructure:** native accounting, event-based tracing, message serialization, and provider configuration.
3. **Reduce the public abstraction:** support native RubyLLM agents/tools directly, then deprecate overlapping ai-agents configuration APIs.

Approvals, cancellation, caching, compaction, fallbacks, and server tools should flow through RubyLLM's APIs as we expose them. Adopting its Rails persistence would be a separate architectural choice because we currently support externally stored context.

The strongest first target is **Runner + history + accounting + tracing**. That would move substantial maintenance upstream while preserving the multi-agent behavior this gem contributes.
