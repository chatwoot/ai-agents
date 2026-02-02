# frozen_string_literal: true

module Agents
  module Instrumentation
    # OpenTelemetry attribute name constants for LLM observability.
    # These follow the GenAI semantic conventions and Langfuse's OTel attribute mapping.
    #
    # @see https://langfuse.com/integrations/native/opentelemetry#property-mapping
    module Constants
      # Span names
      SPAN_RUN      = "agents.run"
      SPAN_LLM_CALL = "agents.llm_call"
      SPAN_TOOL     = "agents.tool.%s"
      EVENT_HANDOFF = "agents.handoff"

      # GenAI semantic conventions (ONLY on generation spans)
      ATTR_GEN_AI_REQUEST_MODEL = "gen_ai.request.model"
      ATTR_GEN_AI_PROVIDER      = "gen_ai.provider.name"
      ATTR_GEN_AI_USAGE_INPUT   = "gen_ai.usage.input_tokens"
      ATTR_GEN_AI_USAGE_OUTPUT  = "gen_ai.usage.output_tokens"

      # Langfuse trace-level attributes
      ATTR_LANGFUSE_USER_ID     = "langfuse.user.id"
      ATTR_LANGFUSE_SESSION_ID  = "langfuse.session.id"
      ATTR_LANGFUSE_TRACE_TAGS  = "langfuse.trace.tags"
      ATTR_LANGFUSE_TRACE_INPUT = "langfuse.trace.input"
      ATTR_LANGFUSE_TRACE_OUTPUT = "langfuse.trace.output"

      # Langfuse observation-level attributes
      ATTR_LANGFUSE_OBS_TYPE   = "langfuse.observation.type"
      ATTR_LANGFUSE_OBS_INPUT  = "langfuse.observation.input"
      ATTR_LANGFUSE_OBS_OUTPUT = "langfuse.observation.output"
    end
  end
end
