# frozen_string_literal: true

# Mirrors how Chatwoot's Captain calls ai-agents, so live specs fail when a change breaks Chatwoot.
# Sources in the Chatwoot repo:
#   enterprise/app/services/captain/assistant/agent_runner_service.rb (agent graph, run payload, callbacks)
#   enterprise/app/models/concerns/agentable.rb (agent options)
#   lib/captain/responses_config.rb (protocol, reasoning effort, temperature)
#   enterprise/lib/captain/response_schema.rb (response schema)
#   enterprise/lib/captain/tools/*.rb (tool shape)
#
# Chatwoot uses RubyLLM's OpenAI provider. These specs use the same provider, pointed at OpenRouter.
module ChatwootLiveHelper
  DEFAULT_MODEL = "openai/gpt-6-luna"
  # gpt-6-luna returns no reasoning items through OpenRouter, so reasoning replay needs another model.
  DEFAULT_REASONING_MODEL = "openai/gpt-5-nano"
  OPENROUTER_API_BASE = "https://openrouter.ai/api/v1"
  RESPONSES_URL = "#{OPENROUTER_API_BASE}/responses".freeze
  CHAT_COMPLETIONS_URL = "#{OPENROUTER_API_BASE}/chat/completions".freeze
  RESOLUTION_MARKER = '<conversation_boundary status="resolved" />'
  DEFAULT_TEMPERATURE = 0.5
  MAX_TURNS = 10
  OPENAI_SETTINGS = %i[openai_api_key openai_api_base openai_protocol].freeze

  # Copy of Captain::ResponseSchema.
  class ResponseSchema < Schematist::Schema
    string :reasoning, description: "Agent's thought process"
    array :response_parts,
          description: "Ordered parts of the message to send to the user. " \
                       "Keep all customer-visible text within each part text field.",
          min_items: 1 do
      object do
        string :text, description: "Customer-visible response text without citation markers or source URLs.",
                      min_length: 1
        array :citation_indexes,
              description: "Numeric citation indexes from FAQ results that support this text. " \
                           "Use an empty array when none apply." do
          integer minimum: 1
        end
      end
    end
  end

  # Mirrors Captain::Tools::BasePublicTool, which overrides execute and calls super.
  class BasePublicTool < Agents::Tool
    def execute(tool_context, **params)
      return "Tool skipped because a newer customer message arrived" if tool_context.state[:newer_message_arrived]

      super
    end
  end

  # Mirrors Captain::Tools::FaqLookupTool: one parameter, writes cw_metadata into the run state.
  class FaqLookupTool < BasePublicTool
    FAQ_ID = 7
    ANSWER = "Refunds are processed within 11 business days."

    description "Search FAQ responses using semantic similarity to find relevant answers"
    parameter :query, type: "string", description: "The question or topic to search for in the FAQ database"

    def perform(tool_context, query:)
      metadata = tool_context.state[:cw_metadata] ||= {}
      metadata[:faq_ids] = Array(metadata[:faq_ids]) | [FAQ_ID]
      "FAQ result:\nQuestion: #{query}\nAnswer: #{ANSWER}\n"
    end
  end

  # Mirrors Captain::Tools::HandoffTool: a parameters block with an enum, and a state flag the caller reads.
  class HandoffTool < BasePublicTool
    REASON_CATEGORIES = %w[customer_request missing_knowledge unsupported_request policy_restriction
                           tool_failure].freeze

    description "Hand off the conversation to a human agent when unable to assist further"
    parameters do
      string :reason, description: "The reason why handoff is needed (optional)", required: false
      string :reason_category, enum: REASON_CATEGORIES, description: "Reporting category for why the handoff is needed"
    end

    def perform(tool_context, reason: nil, reason_category: nil)
      tool_context.state[:captain_v2_handoff_tool_completed] = true
      tool_context.state[:handoff_reason_category] = reason_category
      "Conversation handed off to human support team#{" (Reason: #{reason})" if reason}"
    end
  end

  # Mirrors Captain::Assistant::InstrumentationAttributeProvider. It reads the chat's provider and thinking.
  class AttributeProvider
    def call(context_wrapper)
      state = context_wrapper&.context&.dig(:state) || {}
      { "langfuse.user.id" => state[:account_id].to_s }
    end

    def generation_attributes(_context_wrapper, chat, _message)
      {
        "langfuse.observation.metadata.provider" => chat.provider.slug.to_s,
        "langfuse.observation.metadata.api_protocol" => chat.provider.config.openai_protocol.to_s,
        "langfuse.observation.metadata.reasoning_effort" => chat.thinking&.dig(:effort).to_s
      }
    end
  end

  def chatwoot_reasoning_model
    ENV.fetch("OPENROUTER_REASONING_MODEL", DEFAULT_REASONING_MODEL)
  end

  def chatwoot_model
    ENV.fetch("OPENROUTER_CHATWOOT_MODEL", DEFAULT_MODEL)
  end

  # Chatwoot sets the OpenAI key, a custom base, and chat completions as the global protocol.
  # Agents.configure cannot unset values, so the original settings are restored after each example.
  def with_chatwoot_llm_config
    saved_agents = OPENAI_SETTINGS.to_h { |key| [key, Agents.configuration.send(key)] }
    saved_ruby_llm = OPENAI_SETTINGS.to_h { |key| [key, RubyLLM.config.send(key)] }
    Agents.configure do |config|
      config.openai_api_key = ENV.fetch("OPENROUTER_API_KEY", nil)
      config.openai_api_base = OPENROUTER_API_BASE
      config.openai_protocol = :chat_completions
      config.default_model = chatwoot_model
      config.request_timeout = Integer(ENV.fetch("OPENROUTER_REQUEST_TIMEOUT", 60))
      config.debug = false
    end
    yield
  ensure
    saved_agents.each { |key, value| Agents.configuration.send("#{key}=", value) }
    saved_ruby_llm.each { |key, value| RubyLLM.config.send("#{key}=", value) }
  end

  # Mirrors Concerns::Agentable#agent with Captain::ResponsesConfig.options on the standard OpenAI endpoint.
  # Chatwoot resolves the provider from its own model registry. Here the provider is explicit.
  def chatwoot_agent(name:, prompt:, tools: [], reasoning_effort: :none, protocol: :responses, model: chatwoot_model)
    options = { temperature: DEFAULT_TEMPERATURE }
    if protocol == :responses
      options[:protocol] = :responses
      options[:thinking] = { effort: reasoning_effort }
      options[:temperature] = nil unless reasoning_effort == :none
    end

    Agents::Agent.new(
      name: name,
      instructions: ->(context) { render_instructions(prompt, context) },
      tools: tools,
      model: model,
      provider: :openai,
      assume_model_exists: true,
      response_schema: ResponseSchema,
      **options
    )
  end

  # Mirrors AgentRunnerService#wire_agents: the assistant hands off to each scenario and back.
  def wire_chatwoot_agents(assistant, scenarios = [])
    assistant.register_handoffs(*scenarios) if scenarios.any?
    scenarios.each { |scenario| scenario.register_handoffs(assistant) }
    [assistant] + scenarios
  end

  # Mirrors AgentRunnerService#runner: callbacks, run completion, and instrumentation on every run.
  def chatwoot_runner(agents, events:, span_exporter:)
    runner = Agents::Runner.with_agents(*agents)
    runner.on_agent_thinking { |*args| events << [:agent_thinking, *args.first(2)] }
    runner.on_tool_start { |*args| events << [:tool_start, *args.first(2)] }
    runner.on_tool_complete do |tool_name, tool_result, context_wrapper|
      events << [:tool_complete, tool_name, tool_result, context_wrapper.context[:state].dup]
    end
    runner.on_agent_handoff { |*args| events << [:agent_handoff, *args.first(2)] }
    runner.on_run_complete do |agent_name, result, context_wrapper|
      root_span = context_wrapper&.context&.dig(:__otel_tracing, :root_span)
      root_span&.set_attribute("langfuse.trace.metadata.credit_used", "true")
      events << [:run_complete, agent_name, result]
    end
    Agents::Instrumentation.install(
      runner,
      tracer: chatwoot_tracer(span_exporter),
      trace_name: "llm.captain_v2",
      span_attributes: { "langfuse.trace.tags" => ["captain_v2"].to_json },
      attribute_provider: AttributeProvider.new
    )
    runner
  end

  # Mirrors AgentRunnerService#run_payload: the last user message is the input, and the history omits it.
  def run_like_chatwoot(runner, message_history, state: {})
    last_user_index = message_history.rindex { |msg| msg[:role] == "user" }
    input = message_history[last_user_index][:content]
    history = message_history.reject.with_index { |_msg, index| index == last_user_index }
    context = {
      session_id: "1_42",
      conversation_history: history.map do |msg|
        { role: msg[:role].to_sym, content: msg[:content], agent_name: msg[:agent_name] }
      end,
      state: { account_id: 1, assistant_id: 2, source: "smoke", conversation: { id: 42, display_id: 42 } }
              .merge(state)
    }
    runner.run(input, context: context, max_turns: MAX_TURNS)
  end

  def response_text(output)
    Array(output && output["response_parts"]).map { |part| part["text"] }.join(" ")
  end

  def openrouter_requests(url)
    WebMock::RequestRegistry.instance.requested_signatures.hash.keys
                            .select { |signature| WebMock::RequestPattern.new(:post, url).matches?(signature) }
                            .map { |signature| JSON.parse(signature.body) }
  end

  # Texts of user turns in a Responses API input or a chat completions message list.
  def user_texts(body)
    items = body["input"] || body["messages"]
    items.select { |item| item["role"] == "user" }.flat_map do |item|
      content = item["content"]
      content.is_a?(Array) ? content.filter_map { |part| part["text"] } : [content]
    end
  end

  private

  # Mirrors Agentable#agent_instructions: the prompt reads the run state.
  def render_instructions(prompt, context)
    state = context.context[:state] || {}
    contact = state[:contact] || {}
    "You are Captain, a customer support assistant.\n" \
      "Customer name: #{contact[:name] || "unknown"}\n" \
      "Always answer in the response schema. Put customer-visible text in response_parts.\n" \
      "#{prompt}"
  end

  def chatwoot_tracer(span_exporter)
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    provider.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(span_exporter))
    provider.tracer("chatwoot-live-smoke")
  end
end
