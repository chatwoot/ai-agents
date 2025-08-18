# frozen_string_literal: true

require_relative "tracing/tracer"
require_relative "tracing/instrumentation"
require_relative "tracing/session_context"

module Agents
  module Tracing
    # OpenInference span types
    SPAN_KIND_CHAIN = "CHAIN"
    SPAN_KIND_AGENT = "AGENT"
    SPAN_KIND_LLM = "LLM"
    SPAN_KIND_TOOL = "TOOL"
    
    # Main tracing module for OpenInference-compliant observability
    # Provides non-intrusive callback-based instrumentation for multi-agent conversations
  end
end