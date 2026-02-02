# frozen_string_literal: true

require "json"

module Agents
  module Instrumentation
    # Manages OpenTelemetry span lifecycle for agent execution.
    # Registers as callbacks on an AgentRunner to produce OTel spans that render
    # correctly in Langfuse (and other OTel-compatible backends).
    #
    # ## Span hierarchy (names derived from trace_name, default "agents.run")
    #   Trace (root span)
    #   └── SPAN: <trace_name>                        ← container, NO gen_ai.request.model
    #       ├── GENERATION: <trace_name>.generation   ← gen_ai.request.model + tokens
    #       ├── TOOL: <trace_name>.tool.<name>        ← langfuse.observation.type = "tool"
    #       ├── GENERATION: <trace_name>.generation   ← gen_ai.request.model + tokens
    #       ├── EVENT: <trace_name>.handoff           ← point event on root span
    #       └── GENERATION: <trace_name>.generation   ← gen_ai.request.model + tokens
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
      # @param trace_name [String] Name for the root span (default: "agents.run")
      # @param span_attributes [Hash] Static attributes applied to the root span
      # @param attribute_provider [Proc, nil] Lambda receiving context_wrapper, returning a Hash of dynamic attributes
      def initialize(tracer:, trace_name: SPAN_RUN, span_attributes: {}, attribute_provider: nil)
        @tracer = tracer
        @trace_name = trace_name
        @llm_span_name = "#{trace_name}.generation"
        @tool_span_name = "#{trace_name}.tool.%s"
        @handoff_event_name = "#{trace_name}.handoff"
        @span_attributes = span_attributes
        @attribute_provider = attribute_provider
      end

      # Called when a run starts. Opens the root `agents.run` span.
      # This span is a container — it does NOT carry gen_ai.request.model.
      def on_run_start(agent_name, input, context_wrapper)
        attributes = build_root_attributes(agent_name, input, context_wrapper)

        root_span = @tracer.start_span(@trace_name, attributes: attributes)
        root_context = OpenTelemetry::Trace.context_with_span(root_span)

        store_tracing_state(context_wrapper,
                            root_span: root_span,
                            root_context: root_context,
                            current_tool_span: nil)
      end

      # Called when an agent begins thinking (about to make an LLM call).
      # Captures the input text so the on_end_message hook can attach it to the
      # first LLM GENERATION span of this turn.
      def on_agent_thinking(_agent_name, input, context_wrapper)
        tracing = tracing_state(context_wrapper)
        return unless tracing

        tracing[:pending_llm_input] = input.to_s
      end

      # Called after an LLM call completes.
      # Previously closed the LLM span here, but per-call spans are now handled
      # by the on_end_message hook registered in on_chat_created.
      # This method is kept as a no-op because non-tracing consumers still use
      # the on_llm_call_complete event.
      def on_llm_call_complete(_agent_name, _model, _response, _context_wrapper); end

      # Called when a RubyLLM Chat object is created or reconfigured after handoff.
      # Registers an on_end_message hook to create individual GENERATION spans
      # for each assistant message (each actual LLM API call).
      def on_chat_created(chat, agent_name, model, context_wrapper)
        tracing = tracing_state(context_wrapper)
        return unless tracing

        chat.on_end_message do |message|
          handle_end_message(chat, agent_name, model, message, context_wrapper)
        end
      end

      # Called when a tool begins execution. Opens an `agents.tool.<name>` child span.
      # This span does NOT carry gen_ai.request.model (prevents double counting).
      def on_tool_start(tool_name, args, context_wrapper)
        tracing = tracing_state(context_wrapper)
        return unless tracing

        span_name = format(@tool_span_name, tool_name)
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
          @handoff_event_name,
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

        if result.respond_to?(:output)
          output_text = serialize_output(result.output)
          root_span.set_attribute(ATTR_LANGFUSE_TRACE_OUTPUT, output_text)
          root_span.set_attribute(ATTR_LANGFUSE_OBS_OUTPUT, output_text)
        end

        root_span.finish
        cleanup_tracing_state(context_wrapper)
      end

      private

      # Creates and immediately finishes a GENERATION span for each assistant message.
      # Called by the on_end_message hook registered on the RubyLLM Chat object.
      # Tool result messages are ignored since tool spans are handled by ToolWrapper callbacks.
      #
      # Input is the full chat history (excluding the current response) as a JSON array
      # of {role, content} messages. This naturally includes tool results when they are
      # part of the conversation, matching how the LLM actually sees its context.
      def handle_end_message(chat, _agent_name, model, message, context_wrapper)
        return unless message.respond_to?(:role) && message.role == :assistant

        tracing = tracing_state(context_wrapper)
        return unless tracing

        input = format_chat_messages(chat)
        attrs = {}
        attrs[ATTR_LANGFUSE_OBS_INPUT] = input if input
        llm_span = @tracer.start_span(@llm_span_name, with_parent: tracing[:root_context], attributes: attrs)

        llm_span.set_attribute(ATTR_GEN_AI_REQUEST_MODEL, model) if model
        set_llm_response_attributes(llm_span, message)

        llm_span.finish
      end

      # Close any child spans that were opened but never finished (e.g. due to exceptions).
      def finish_dangling_spans(tracing)
        return unless tracing[:current_tool_span]

        tracing[:current_tool_span].finish
        tracing[:current_tool_span] = nil
      end

      def set_llm_response_attributes(span, response)
        if response.respond_to?(:input_tokens) && response.input_tokens
          span.set_attribute(ATTR_GEN_AI_USAGE_INPUT, response.input_tokens)
        end
        if response.respond_to?(:output_tokens) && response.output_tokens
          span.set_attribute(ATTR_GEN_AI_USAGE_OUTPUT, response.output_tokens)
        end
        output = llm_output_text(response)
        span.set_attribute(ATTR_LANGFUSE_OBS_OUTPUT, output) unless output.empty?
      end

      # Extract meaningful output text from an LLM response.
      # When the assistant message is a tool-call-only message (no text content),
      # format the tool calls as the output so Langfuse shows something useful.
      # When content is a Hash or Array (structured output from response_schema),
      # serialize as JSON for readable display in Langfuse.
      def llm_output_text(response)
        return format_tool_calls(response) unless response.respond_to?(:content)

        content = response.content
        return format_tool_calls(response) if content.nil?

        text = content.is_a?(Hash) || content.is_a?(Array) ? content.to_json : content.to_s
        return format_tool_calls(response) if text.empty?

        text
      end

      # Format chat messages as a JSON array of {role, content} hashes, excluding
      # the last message (the current assistant response). This mirrors what was
      # actually sent to the LLM — including system prompt, user messages, prior
      # assistant messages, and tool results — so each generation span shows its
      # full input context with proper role separation.
      def format_chat_messages(chat)
        return nil unless chat.respond_to?(:messages)

        messages = chat.messages
        return nil if messages.nil? || messages.empty?

        messages[0...-1].map { |m| { role: m.role.to_s, content: m.content.to_s } }.to_json
      end

      def serialize_output(value)
        value.is_a?(Hash) || value.is_a?(Array) ? value.to_json : value.to_s
      end

      def format_tool_calls(response)
        return "" unless response.respond_to?(:tool_calls) && response.tool_calls&.any?

        calls = response.tool_calls.values.map { |tc| "#{tc.name}(#{tc.arguments})" }
        "Tool calls: #{calls.join(", ")}"
      end

      def build_root_attributes(agent_name, input, context_wrapper)
        attributes = @span_attributes.dup
        attributes[ATTR_LANGFUSE_TRACE_INPUT] = input.to_s
        attributes[ATTR_LANGFUSE_OBS_INPUT] = input.to_s
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
