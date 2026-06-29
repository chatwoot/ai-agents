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

      CHILD_LANGFUSE_EXCLUDED_ATTRIBUTES = [
        ATTR_LANGFUSE_TRACE_INPUT,
        ATTR_LANGFUSE_TRACE_OUTPUT,
        ATTR_LANGFUSE_OBS_INPUT,
        ATTR_LANGFUSE_OBS_OUTPUT,
        ATTR_LANGFUSE_OBS_TYPE
      ].freeze
      private_constant :CHILD_LANGFUSE_EXCLUDED_ATTRIBUTES

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
        child_attributes = build_child_langfuse_attributes(attributes)

        root_span = @tracer.start_span(@trace_name, attributes: attributes)
        root_context = OpenTelemetry::Trace.context_with_span(root_span)

        store_tracing_state(context_wrapper,
                            root_span: root_span,
                            root_context: root_context,
                            child_langfuse_attributes: child_attributes,
                            current_tool_span: nil,
                            current_agent_name: nil,
                            current_agent_span: nil,
                            current_agent_context: nil)
      end

      def on_agent_thinking(agent_name, input, context_wrapper)
        tracing = tracing_state(context_wrapper)
        return unless tracing

        tracing[:pending_llm_input] = serialize_output(input)

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
        attributes.merge!(tracing[:child_langfuse_attributes])

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

        llm_span = @tracer.start_span(
          @llm_span_name,
          with_parent: parent_context(tracing),
          attributes: generation_span_attributes(tracing, chat, message, context_wrapper)
        )

        llm_span.set_attribute(ATTR_GEN_AI_REQUEST_MODEL, model) if model

        output = llm_output_text(message)
        set_llm_response_attributes(llm_span, message, output)
        tracing[:last_agent_output] = output unless output.empty?

        llm_span.finish
      end

      def generation_span_attributes(tracing, chat, message, context_wrapper)
        attrs = tracing[:child_langfuse_attributes].dup
        input = format_chat_messages(chat)
        attrs[ATTR_LANGFUSE_OBS_INPUT] = input if input
        apply_generation_dynamic_attributes(attrs, context_wrapper, chat, message)
        attrs
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

      def set_llm_response_attributes(span, response, output)
        if response.respond_to?(:input_tokens) && response.input_tokens
          span.set_attribute(ATTR_GEN_AI_USAGE_INPUT, response.input_tokens)
        end
        if response.respond_to?(:output_tokens) && response.output_tokens
          span.set_attribute(ATTR_GEN_AI_USAGE_OUTPUT, response.output_tokens)
        end
        span.set_attribute(ATTR_LANGFUSE_OBS_OUTPUT, output) unless output.empty?
      end

      # Returns serialized text content if present, otherwise falls back to tool call formatting.
      # Uses .to_json for Hash/Array (structured output) to avoid Ruby's .to_s format.
      def llm_output_text(response)
        if response.respond_to?(:content) && response.content
          text = serialize_output(response.content)
          return text unless text.empty?
        end

        format_tool_calls(response)
      end

      # Excludes the last message (current response) — returns what was sent to the LLM.
      def format_chat_messages(chat)
        return nil unless chat.respond_to?(:messages)

        messages = chat.messages
        return nil if messages.nil? || messages.empty?

        messages[0...-1].map { |m| format_single_message(m) }.to_json
      end

      def format_single_message(msg)
        text = serialize_output(msg.content)
        text = append_tool_calls(msg, text)
        { role: msg.role.to_s, content: text }
      end

      def append_tool_calls(msg, text)
        return text unless msg.role == :assistant && msg.respond_to?(:tool_calls) && msg.tool_calls&.any?

        calls = msg.tool_calls.values.map { |tc| "#{tc.name}(#{serialize_output(tc.arguments)})" }.join(", ")
        text.empty? ? "Tool calls: #{calls}" : "#{text}\nTool calls: #{calls}"
      end

      def serialize_output(value)
        return serialize_multimodal_content(value) if multimodal_content?(value)

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
        agent_span = @tracer.start_span(span_name,
                                        with_parent: tracing[:root_context],
                                        attributes: agent_span_attributes(tracing, agent_name))
        agent_context = OpenTelemetry::Trace.context_with_span(agent_span)

        tracing[:current_agent_name] = agent_name
        tracing[:current_agent_span] = agent_span
        tracing[:current_agent_context] = agent_context
        tracing[:last_agent_output] = nil
      end

      def agent_span_attributes(tracing, agent_name)
        attrs = tracing[:child_langfuse_attributes].merge("agent.name" => agent_name)
        input = tracing[:pending_llm_input]
        attrs[ATTR_LANGFUSE_OBS_INPUT] = input if input && !input.empty?
        attrs
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

      def build_child_langfuse_attributes(root_attributes)
        root_attributes.each_with_object({}) do |(key, value), attrs|
          next if value.nil?
          next unless child_langfuse_attribute?(key)

          attrs[key] = value
          add_observation_metadata_mirror(attrs, key, value) if mirrored_observation_metadata_attribute?(key)
        end
      end

      def child_langfuse_attribute?(key)
        key.start_with?(ATTR_LANGFUSE_PREFIX) && !child_langfuse_excluded_attribute?(key)
      end

      def child_langfuse_excluded_attribute?(key)
        CHILD_LANGFUSE_EXCLUDED_ATTRIBUTES.include?(key)
      end

      def mirrored_observation_metadata_attribute?(key)
        key == ATTR_LANGFUSE_USER_ID ||
          key == ATTR_LANGFUSE_SESSION_ID ||
          key == ATTR_LANGFUSE_TRACE_TAGS ||
          key.start_with?(ATTR_LANGFUSE_TRACE_METADATA_PREFIX)
      end

      def add_observation_metadata_mirror(attrs, key, value)
        metadata_key = observation_metadata_mirror_key(key)
        attrs[observation_metadata_key(metadata_key)] = serialize_metadata_value(value)
      end

      def observation_metadata_mirror_key(key)
        case key
        when ATTR_LANGFUSE_USER_ID
          "user_id"
        when ATTR_LANGFUSE_SESSION_ID
          "session_id"
        when ATTR_LANGFUSE_TRACE_TAGS
          "trace_tags"
        else
          key.delete_prefix(ATTR_LANGFUSE_TRACE_METADATA_PREFIX)
        end
      end

      def observation_metadata_key(key)
        "#{ATTR_LANGFUSE_OBS_METADATA_PREFIX}#{key}"
      end

      def serialize_metadata_value(value)
        value.is_a?(Hash) || value.is_a?(Array) ? value.to_json : value.to_s
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

      def apply_generation_dynamic_attributes(attributes, context_wrapper, chat, message)
        return unless @attribute_provider.respond_to?(:generation_attributes)

        dynamic_attrs = @attribute_provider.generation_attributes(context_wrapper, chat, message)
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

      def multimodal_content?(value)
        value.respond_to?(:text) && value.respond_to?(:attachments)
      end

      def serialize_multimodal_content(content)
        parts = []
        text = content.text
        parts << text if text && !text.empty?

        if content.attachments&.any?
          urls = content.attachments.map { |a| a.respond_to?(:source) ? a.source.to_s : a.to_s }
          parts << "Attachments: #{urls.join(", ")}"
        end

        parts.join("\n")
      end
    end
  end
end
