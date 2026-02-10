# frozen_string_literal: true

require "json"

module Agents
  module Instrumentation
    # Produces OTel spans for agent execution, compatible with Langfuse.
    #
    # Span hierarchy:
    #   root (<trace_name>)
    #   ├── agent.<name>        ← container per agent (no gen_ai.request.model)
    #   │   ├── .generation     ← GENERATION with model + tokens
    #   │   └── .tool.<name>    ← TOOL observation
    #   └── .handoff            ← point event on root
    #
    # Only GENERATION spans carry gen_ai.request.model to avoid Langfuse double-counting costs.
    # Tracing state lives in context[:__otel_tracing], unique per run (thread-safe).
    class TracingCallbacks
      include Constants

      def initialize(tracer:, trace_name: SPAN_RUN, span_attributes: {}, attribute_provider: nil)
        @tracer = tracer
        @trace_name = trace_name
        @llm_span_name = "#{trace_name}.generation"
        @tool_span_name = "#{trace_name}.tool.%s"
        @agent_span_name = "#{trace_name}.agent.%s"
        @handoff_event_name = "#{trace_name}.handoff"
        @span_attributes = span_attributes
        @attribute_provider = attribute_provider
      end

      def on_run_start(agent_name, input, context_wrapper)
        attributes = build_root_attributes(agent_name, input, context_wrapper)

        root_span = @tracer.start_span(@trace_name, attributes: attributes)
        root_context = OpenTelemetry::Trace.context_with_span(root_span)

        store_tracing_state(context_wrapper,
                            root_span: root_span,
                            root_context: root_context,
                            current_tool_span: nil,
                            current_agent_name: nil,
                            current_agent_span: nil,
                            current_agent_context: nil)
      end

      def on_agent_thinking(agent_name, input, context_wrapper)
        tracing = tracing_state(context_wrapper)
        return unless tracing

        tracing[:pending_llm_input] = input.to_s

        return if tracing[:current_agent_name] == agent_name

        start_agent_span(tracing, agent_name)
      end

      # No-op: LLM spans are handled by on_end_message hook (see on_chat_created).
      # Kept because the callback interface requires it.
      def on_llm_call_complete(_agent_name, _model, _response, _context_wrapper); end

      def on_agent_complete(_agent_name, _result, _error, context_wrapper)
        tracing = tracing_state(context_wrapper)
        return unless tracing

        finish_agent_span(tracing)
      end

      def on_chat_created(chat, agent_name, model, context_wrapper)
        tracing = tracing_state(context_wrapper)
        return unless tracing

        chat.on_end_message do |message|
          handle_end_message(chat, agent_name, model, message, context_wrapper)
        end
      end

      def on_tool_start(tool_name, args, context_wrapper)
        tracing = tracing_state(context_wrapper)
        return unless tracing

        span_name = format(@tool_span_name, tool_name)
        attributes = {
          ATTR_LANGFUSE_OBS_TYPE => "tool",
          ATTR_LANGFUSE_OBS_INPUT => serialize_output(args)
        }

        parent = handoff_tool?(tool_name) ? tracing[:root_context] : parent_context(tracing)
        tool_span = @tracer.start_span(
          span_name,
          with_parent: parent,
          attributes: attributes
        )

        tracing[:current_tool_span] = tool_span
      end

      def on_tool_complete(_tool_name, result, context_wrapper)
        tracing = tracing_state(context_wrapper)
        return unless tracing

        tool_span = tracing[:current_tool_span]
        return unless tool_span

        tool_span.set_attribute(ATTR_LANGFUSE_OBS_OUTPUT, serialize_output(result))
        tool_span.finish
        tracing[:current_tool_span] = nil
      end

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

      def on_run_complete(_agent_name, result, context_wrapper)
        tracing = tracing_state(context_wrapper)
        return unless tracing

        finish_dangling_spans(tracing)

        root_span = tracing[:root_span]
        return unless root_span

        set_run_output_attributes(root_span, result)
        set_run_error_status(root_span, result)

        root_span.finish
        cleanup_tracing_state(context_wrapper)
      end

      private

      def handle_end_message(chat, _agent_name, model, message, context_wrapper)
        return unless message.respond_to?(:role) && message.role == :assistant

        tracing = tracing_state(context_wrapper)
        return unless tracing

        input = format_chat_messages(chat)
        attrs = {}
        attrs[ATTR_LANGFUSE_OBS_INPUT] = input if input
        llm_span = @tracer.start_span(@llm_span_name, with_parent: parent_context(tracing), attributes: attrs)

        llm_span.set_attribute(ATTR_GEN_AI_REQUEST_MODEL, model) if model
        set_llm_response_attributes(llm_span, message)

        output = llm_output_text(message)
        tracing[:last_agent_output] = output unless output.empty?

        llm_span.finish
      end

      def finish_dangling_spans(tracing)
        if tracing[:current_tool_span]
          tracing[:current_tool_span].finish
          tracing[:current_tool_span] = nil
        end
        finish_agent_span(tracing)
      end

      def set_run_output_attributes(root_span, result)
        return unless result.respond_to?(:output)

        output_text = serialize_output(result.output)
        return if output_text.empty?

        root_span.set_attribute(ATTR_LANGFUSE_TRACE_OUTPUT, output_text)
        root_span.set_attribute(ATTR_LANGFUSE_OBS_OUTPUT, output_text)
      end

      def set_run_error_status(root_span, result)
        return unless result.respond_to?(:error)

        error = result.error
        return unless error

        root_span.record_exception(error)
        root_span.status = OpenTelemetry::Trace::Status.error(error.message)
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

      # Falls back to formatting tool calls when response has no text content,
      # and uses .to_json for Hash/Array (structured output) to avoid Ruby's .to_s format.
      def llm_output_text(response)
        return format_tool_calls(response) unless response.respond_to?(:content)

        content = response.content
        return format_tool_calls(response) if content.nil?

        text = content.is_a?(Hash) || content.is_a?(Array) ? content.to_json : content.to_s
        return format_tool_calls(response) if text.empty?

        text
      end

      # Excludes the last message (current response) — returns what was sent to the LLM.
      def format_chat_messages(chat)
        return nil unless chat.respond_to?(:messages)

        messages = chat.messages
        return nil if messages.nil? || messages.empty?

        messages[0...-1].map { |m| format_single_message(m) }.to_json
      end

      def format_single_message(msg)
        text = serialize_content(msg.content)
        text = append_tool_calls(msg, text)
        { role: msg.role.to_s, content: text }
      end

      def serialize_content(content)
        content.is_a?(Hash) || content.is_a?(Array) ? content.to_json : content.to_s
      end

      def append_tool_calls(msg, text)
        return text unless msg.role == :assistant && msg.respond_to?(:tool_calls) && msg.tool_calls&.any?

        calls = msg.tool_calls.values.map { |tc| "#{tc.name}(#{tc.arguments.to_json})" }.join(", ")
        text.empty? ? "Tool calls: #{calls}" : "#{text}\nTool calls: #{calls}"
      end

      def serialize_output(value)
        value.is_a?(Hash) || value.is_a?(Array) ? value.to_json : value.to_s
      end

      def format_tool_calls(response)
        return "" unless response.respond_to?(:tool_calls) && response.tool_calls&.any?

        calls = response.tool_calls.values.map do |tc|
          "#{tc.name}(#{serialize_output(tc.arguments)})"
        end
        "Tool calls: #{calls.join(", ")}"
      end

      def start_agent_span(tracing, agent_name)
        finish_agent_span(tracing) # close previous agent span if missed

        span_name = format(@agent_span_name, agent_name)
        attrs = { "agent.name" => agent_name }
        input = tracing[:pending_llm_input]
        attrs[ATTR_LANGFUSE_OBS_INPUT] = input if input && !input.empty?

        agent_span = @tracer.start_span(span_name,
                                        with_parent: tracing[:root_context],
                                        attributes: attrs)
        agent_context = OpenTelemetry::Trace.context_with_span(agent_span)

        tracing[:current_agent_name] = agent_name
        tracing[:current_agent_span] = agent_span
        tracing[:current_agent_context] = agent_context
        tracing[:last_agent_output] = nil
      end

      def finish_agent_span(tracing)
        return unless tracing[:current_agent_span]

        last_output = tracing[:last_agent_output]
        if last_output && !last_output.empty?
          tracing[:current_agent_span].set_attribute(ATTR_LANGFUSE_OBS_OUTPUT, last_output)
        end

        tracing[:current_agent_span].finish
        tracing[:current_agent_name] = nil
        tracing[:current_agent_span] = nil
        tracing[:current_agent_context] = nil
        tracing[:last_agent_output] = nil
      end

      def parent_context(tracing)
        tracing[:current_agent_context] || tracing[:root_context]
      end

      def handoff_tool?(tool_name)
        tool_name.to_s.start_with?("handoff_to_")
      end

      def build_root_attributes(agent_name, input, context_wrapper)
        attributes = @span_attributes.dup
        apply_session_id(attributes, context_wrapper)
        apply_input(attributes, input)
        attributes["agent.name"] = agent_name
        apply_dynamic_attributes(attributes, context_wrapper)
        attributes
      end

      def apply_session_id(attributes, context_wrapper)
        session_id = context_wrapper&.context&.dig(:session_id)&.to_s
        attributes[ATTR_LANGFUSE_SESSION_ID] = session_id if session_id && !session_id.empty?
      end

      def apply_input(attributes, input)
        serialized_input = serialize_output(input)
        return if serialized_input.empty?

        attributes[ATTR_LANGFUSE_TRACE_INPUT] = serialized_input
        attributes[ATTR_LANGFUSE_OBS_INPUT] = serialized_input
      end

      def apply_dynamic_attributes(attributes, context_wrapper)
        return unless @attribute_provider

        dynamic_attrs = @attribute_provider.call(context_wrapper)
        attributes.merge!(dynamic_attrs) if dynamic_attrs.is_a?(Hash)
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
