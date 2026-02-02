# frozen_string_literal: true

module Agents
  module Instrumentation
    # Manages OpenTelemetry span lifecycle for agent execution.
    # Registers as callbacks on an AgentRunner to produce OTel spans that render
    # correctly in Langfuse (and other OTel-compatible backends).
    #
    # ## Span hierarchy
    #   Trace (root span)
    #   └── SPAN: agents.run                    ← container, NO gen_ai.request.model
    #       ├── GENERATION: agents.llm_call     ← gen_ai.request.model + tokens
    #       ├── TOOL: agents.tool.<name>        ← langfuse.observation.type = "tool"
    #       ├── GENERATION: agents.llm_call     ← gen_ai.request.model + tokens
    #       ├── EVENT: agents.handoff           ← point event on root span
    #       └── GENERATION: agents.llm_call     ← gen_ai.request.model + tokens
    #
    # ## Double-counting prevention
    # Only LLM call spans carry `gen_ai.request.model`, which Langfuse uses to
    # classify observations as GENERATION (and sum costs). Container spans
    # (run, tool) intentionally omit this attribute so they appear as SPAN/TOOL
    # and are not double-counted.
    #
    # ## Thread safety
    # Tracing state is stored in `context_wrapper.context[:__otel_tracing]`, which
    # is unique per execution (each run gets its own deep-copied context).
    #
    # ## Limitation: single-slot span tracking
    # Only one LLM span and one tool span are tracked at a time (current_llm_span,
    # current_tool_span). RubyLLM currently executes tool calls sequentially, so this
    # is sufficient. If parallel/nested tool calls are supported in the future, this
    # should be changed to a stack or call-id keyed map.
    class TracingCallbacks
      include Constants

      # @param tracer [OpenTelemetry::Trace::Tracer] OTel tracer instance
      # @param span_attributes [Hash] Static attributes applied to the root span
      # @param attribute_provider [Proc, nil] Lambda receiving context_wrapper, returning a Hash of dynamic attributes
      def initialize(tracer:, span_attributes: {}, attribute_provider: nil)
        @tracer = tracer
        @span_attributes = span_attributes
        @attribute_provider = attribute_provider
      end

      # Called when a run starts. Opens the root `agents.run` span.
      # This span is a container — it does NOT carry gen_ai.request.model.
      def on_run_start(agent_name, input, context_wrapper)
        attributes = build_root_attributes(agent_name, input, context_wrapper)

        root_span = @tracer.start_span(SPAN_RUN, attributes: attributes)
        root_context = OpenTelemetry::Trace.context_with_span(root_span)

        store_tracing_state(context_wrapper,
                            root_span: root_span,
                            root_context: root_context,
                            current_llm_span: nil,
                            current_tool_span: nil)
      end

      # Called when an agent begins thinking (about to make an LLM call).
      # Opens an `agents.llm_call` child span. Model and tokens are set on close.
      def on_agent_thinking(_agent_name, input, context_wrapper)
        tracing = tracing_state(context_wrapper)
        return unless tracing

        attributes = { ATTR_LANGFUSE_OBS_INPUT => input.to_s }
        llm_span = @tracer.start_span(
          SPAN_LLM_CALL,
          with_parent: tracing[:root_context],
          attributes: attributes
        )

        tracing[:current_llm_span] = llm_span
      end

      # Called after an LLM call completes. Closes the LLM span as a GENERATION
      # by setting gen_ai.request.model and token usage attributes.
      def on_llm_call_complete(_agent_name, model, response, context_wrapper)
        tracing = tracing_state(context_wrapper)
        return unless tracing

        llm_span = tracing[:current_llm_span]
        return unless llm_span

        # Set model — this is what makes Langfuse classify it as GENERATION
        llm_span.set_attribute(ATTR_GEN_AI_REQUEST_MODEL, model) if model
        set_llm_response_attributes(llm_span, response)

        llm_span.finish
        tracing[:current_llm_span] = nil
      end

      # Called when a tool begins execution. Opens an `agents.tool.<name>` child span.
      # This span does NOT carry gen_ai.request.model (prevents double counting).
      def on_tool_start(tool_name, args, context_wrapper)
        tracing = tracing_state(context_wrapper)
        return unless tracing

        span_name = format(SPAN_TOOL, tool_name)
        attributes = {
          ATTR_LANGFUSE_OBS_TYPE => "tool",
          ATTR_LANGFUSE_OBS_INPUT => args.to_s
        }

        tool_span = @tracer.start_span(
          span_name,
          with_parent: tracing[:root_context],
          attributes: attributes
        )

        tracing[:current_tool_span] = tool_span
      end

      # Called when a tool finishes execution. Closes the tool span with output.
      def on_tool_complete(_tool_name, result, context_wrapper)
        tracing = tracing_state(context_wrapper)
        return unless tracing

        tool_span = tracing[:current_tool_span]
        return unless tool_span

        tool_span.set_attribute(ATTR_LANGFUSE_OBS_OUTPUT, result.to_s)
        tool_span.finish
        tracing[:current_tool_span] = nil
      end

      # Called on agent handoff. Adds a point event to the root span (not a child span).
      def on_agent_handoff(from_agent, to_agent, reason, context_wrapper)
        tracing = tracing_state(context_wrapper)
        return unless tracing

        tracing[:root_span]&.add_event(
          EVENT_HANDOFF,
          attributes: {
            "handoff.from" => from_agent,
            "handoff.to" => to_agent,
            "handoff.reason" => reason.to_s
          }
        )
      end

      # Called when the run completes. Closes any pending child spans and the root span.
      # This handles the case where chat.ask/complete raises — the LLM span opened in
      # on_agent_thinking would never be closed by on_llm_call_complete, so we clean it up here.
      def on_run_complete(_agent_name, result, context_wrapper)
        tracing = tracing_state(context_wrapper)
        return unless tracing

        # Close any dangling child spans (e.g. LLM call that raised before on_llm_call_complete)
        finish_dangling_spans(tracing)

        root_span = tracing[:root_span]
        return unless root_span

        root_span.set_attribute(ATTR_LANGFUSE_TRACE_OUTPUT, result.output.to_s) if result.respond_to?(:output)

        root_span.finish
        cleanup_tracing_state(context_wrapper)
      end

      private

      # Close any child spans that were opened but never finished (e.g. due to exceptions).
      def finish_dangling_spans(tracing)
        if tracing[:current_tool_span]
          tracing[:current_tool_span].finish
          tracing[:current_tool_span] = nil
        end
        return unless tracing[:current_llm_span]

        tracing[:current_llm_span].finish
        tracing[:current_llm_span] = nil
      end

      def set_llm_response_attributes(span, response)
        if response.respond_to?(:input_tokens) && response.input_tokens
          span.set_attribute(ATTR_GEN_AI_USAGE_INPUT, response.input_tokens)
        end
        if response.respond_to?(:output_tokens) && response.output_tokens
          span.set_attribute(ATTR_GEN_AI_USAGE_OUTPUT, response.output_tokens)
        end
        span.set_attribute(ATTR_LANGFUSE_OBS_OUTPUT, response.content.to_s) if response.respond_to?(:content)
      end

      def build_root_attributes(agent_name, input, context_wrapper)
        attributes = @span_attributes.dup
        attributes[ATTR_LANGFUSE_TRACE_INPUT] = input.to_s
        attributes["agent.name"] = agent_name

        # Merge dynamic attributes from provider
        if @attribute_provider
          dynamic_attrs = @attribute_provider.call(context_wrapper)
          attributes.merge!(dynamic_attrs) if dynamic_attrs.is_a?(Hash)
        end

        attributes
      end

      def store_tracing_state(context_wrapper, **state)
        context_wrapper.context[:__otel_tracing] = state
      end

      def tracing_state(context_wrapper)
        context_wrapper&.context&.dig(:__otel_tracing)
      end

      def cleanup_tracing_state(context_wrapper)
        context_wrapper.context.delete(:__otel_tracing)
      end
    end
  end
end
