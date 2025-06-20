# frozen_string_literal: true

module Agents
  module Tracing
    # Simple tracer for debugging and monitoring agent operations
    class Tracer
      def initialize(config = {})
        @config = config
        @enabled = config.fetch(:enabled, true)
      end

      # Start an agent trace
      def start_agent_trace(agent_class, input, context = {})
        return NullTrace.new unless @enabled
        AgentTrace.new(agent_class, input, context)
      end

      # Start a tool trace
      def start_tool_trace(tool, method_name, params = {})
        return NullTrace.new unless @enabled
        ToolTrace.new(tool, method_name, params)
      end

      # Start a handoff trace
      def start_handoff_trace(source_agent, target_agent, reason = nil, context = {})
        return NullTrace.new unless @enabled
        HandoffTrace.new(source_agent, target_agent, reason, context)
      end
    end

    # Base trace class
    class BaseTrace
      attr_reader :start_time, :duration

      def initialize
        @start_time = Time.now
        @duration = nil
        @finished = false
      end

      def finish(result = nil)
        return if @finished
        @duration = Time.now - @start_time
        @finished = true
        @result = result
        log_completion if should_log?
      end

      def finished?
        @finished
      end

      private

      def should_log?
        false # Override in subclasses
      end

      def log_completion
        # Override in subclasses
      end
    end

    # Agent execution trace
    class AgentTrace < BaseTrace
      def initialize(agent_class, input, context)
        super()
        @agent_class = agent_class
        @input = input
        @context = context
      end

      def display_name
        @agent_class.name
      end

      private

      def should_log?
        true
      end

      def log_completion
        puts "[AGENT] #{@agent_class.name} completed in #{(@duration * 1000).round}ms"
      end
    end

    # Tool execution trace
    class ToolTrace < BaseTrace
      def initialize(tool, method_name, params)
        super()
        @tool = tool
        @method_name = method_name
        @params = params
      end

      def display_name
        "#{@tool.class.name}##{@method_name}"
      end

      private

      def should_log?
        true
      end

      def log_completion
        puts "[TOOL] #{@tool.class.name} completed in #{(@duration * 1000).round}ms"
      end
    end

    # Handoff trace
    class HandoffTrace < BaseTrace
      def initialize(source_agent, target_agent, reason, context)
        super()
        @source_agent = source_agent
        @target_agent = target_agent
        @reason = reason
        @context = context
      end

      def display_name
        "#{@source_agent.name} → #{@target_agent.name}"
      end

      private

      def should_log?
        true
      end

      def log_completion
        puts "[HANDOFF] #{@source_agent.name} → #{@target_agent.name}"
      end
    end

    # Null object for when tracing is disabled
    class NullTrace
      def finish(result = nil); end
      def finished?; true; end
      def display_name; ""; end
    end
  end
end
