# frozen_string_literal: true

module Agents
  module Tracing
    class Instrumentation
      def self.setup_callbacks(runner, tracer)
        new(runner, tracer).setup
      end

      def initialize(runner, tracer)
        @runner = runner
        @tracer = tracer
        @current_chain_span = nil
        @current_agent_span = nil
        @current_tool_span = nil
      end

      def setup
        setup_chain_span
        setup_agent_callbacks
        setup_tool_callbacks
      end

      private

      def setup_chain_span
        # For now, create the chain span when first callback is triggered
        # TODO: Implement proper chain span lifecycle
      end

      def setup_agent_callbacks
        @runner.on_agent_thinking do |agent_name, input|
          start_agent_span(agent_name, input)
        end

        @runner.on_agent_handoff do |from_agent, to_agent, reason|
          record_handoff(from_agent, to_agent, reason)
        end
      end

      def setup_tool_callbacks
        @runner.on_tool_start do |tool_name, args|
          start_tool_span(tool_name, args)
        end

        @runner.on_tool_complete do |tool_name, result|
          end_tool_span(tool_name, result)
        end
      end

      def start_agent_span(agent_name, input)
        # End previous agent span if exists
        end_agent_span if @current_agent_span

        @current_agent_span = @tracer.otel_tracer.start_span(
          "#{agent_name} Agent",
          attributes: {
            "openinference.span.kind" => SPAN_KIND_AGENT,
            "agent.name" => agent_name,
            "input.value" => input.to_s,
            "input.mime_type" => "text/plain"
          }
        )

        # Make current for child spans
        context = OpenTelemetry::Trace.context_with_span(@current_agent_span)
        @agent_context_token = OpenTelemetry::Context.attach(context)
      end

      def end_agent_span
        if @current_agent_span
          @current_agent_span.finish
          @current_agent_span = nil
        end
        
        if @agent_context_token
          OpenTelemetry::Context.detach(@agent_context_token)
          @agent_context_token = nil
        end
      end

      def record_handoff(from_agent, to_agent, reason)
        if @current_agent_span
          # Record handoff as event
          @current_agent_span.add_event(
            "agent.handoff",
            attributes: {
              "agent.handoff.from" => from_agent,
              "agent.handoff.to" => to_agent,
              "agent.handoff.reason" => reason
            }
          )

          # Set output and end current agent span
          @current_agent_span.set_attribute("output.value", reason)
          @current_agent_span.set_attribute("output.mime_type", "text/plain")
          end_agent_span
        end
      end

      def start_tool_span(tool_name, args)
        @current_tool_span = @tracer.otel_tracer.start_span(
          tool_name,
          attributes: {
            "openinference.span.kind" => SPAN_KIND_TOOL,
            "tool.name" => tool_name,
            "input.value" => args.to_json
          }
        )
      end

      def end_tool_span(tool_name, result)
        if @current_tool_span
          @current_tool_span.set_attribute("output.value", result.to_json) if result
          @current_tool_span.finish
          @current_tool_span = nil
        end
      end
    end
  end
end