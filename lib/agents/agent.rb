# frozen_string_literal: true

module Agents
  # Base class for AI agents with a Ruby-like DSL
  #
  # @example Define a simple agent
  #   class WeatherAgent < Agents::Agent
  #     name "Weather Assistant"
  #     instructions "Help users get weather information"
  #     provider :openai
  #     model "gpt-4o-mini"
  #
  #     uses WeatherTool
  #   end
  #
  # @example Use an agent
  #   agent = WeatherAgent.new
  #   result = agent.call("What's the weather in Tokyo?")
  class Agent
    class << self
      attr_reader :agent_name, :agent_instructions, :agent_provider, :agent_model, :agent_tools, :handoff_targets

      # Set or get the agent name
      def name(value = nil)
        @agent_name = value if value
        @agent_name || to_s.split("::").last.gsub(/Agent$/, "")
      end

      # Set or get the agent instructions
      def instructions(value = nil)
        @agent_instructions = value if value
        @agent_instructions || "You are a helpful AI assistant."
      end

      # Set or get the provider
      def provider(value = nil)
        @agent_provider = value if value
        @agent_provider || Agents.configuration&.default_provider || :openai
      end

      # Set or get the model
      def model(value = nil)
        @agent_model = value if value
        @agent_model || Agents.configuration&.default_model || "gpt-4o-mini"
      end

      # Register tool classes for this agent
      def uses(*tool_classes)
        @agent_tools ||= []
        tool_classes.each do |tool_class|
          @agent_tools << tool_class unless @agent_tools.include?(tool_class)
        end
      end

      # Get all registered tools
      def tools
        @agent_tools || []
      end

      # Define possible handoff targets for this agent
      def handoffs(*targets)
        return @handoff_targets ||= [] if targets.empty?
        @handoff_targets = targets.flatten
      end

      # Create and call agent in one step (class-level callable interface)
      def call(input, context: {}, **options)
        new.call(input, context: context, **options)
      end
    end

    # Initialize a new agent instance
    def initialize(context: {})
      @context = context.is_a?(Context) ? context : Context.new(context)
    end

    # Main callable interface for the agent
    def call(input, context: {}, **options)
      # Start agent trace
      agent_trace = Agents.start_agent_trace(self.class, input, context)

      begin
        # Merge contexts
        execution_context = merge_contexts(context)
        
        # Apply input guardrails if available
        if defined?(Agents::Guardrails::SimpleGuardrails)
          guardrail_check = Agents::Guardrails::SimpleGuardrails.apply_to_agent_call(self, input, execution_context)
          unless guardrail_check[:allowed]
            # Return filtered response without calling LLM
            filtered_response = Agents::Guardrails::SimpleGuardrails.send(:create_guardrail_response, guardrail_check, :input)
            agent_response = AgentResponse.new(content: filtered_response)
            agent_trace&.finish(agent_response)
            return agent_response
          end
        end
        
        # Get provider instance
        provider = get_provider(options)
        
        # Build messages and tools
        messages = build_messages(input, execution_context)
        tools = build_tools

        # Make LLM request
        response = provider.chat(messages, 
                                model: options[:model] || self.class.model,
                                tools: tools.empty? ? nil : tools,
                                **options.except(:provider, :model))

        # Handle tool calls if present
        result = if response[:tool_calls]
                   handle_tool_calls(response[:tool_calls], execution_context)
                 else
                   response[:content] || ""
                 end

        # Apply output guardrails if available
        if defined?(Agents::Guardrails::SimpleGuardrails)
          result = Agents::Guardrails::SimpleGuardrails.enhance_response(self.class, result, execution_context)
        end

        # Check for handoffs
        handoff_result = detect_handoff(execution_context)

        # Create response
        agent_response = AgentResponse.new(content: result, handoff_result: handoff_result)
        
        # Finish trace
        agent_trace&.finish(agent_response)
        
        agent_response
      rescue => e
        agent_trace&.finish(e)
        raise ExecutionError, "Agent execution failed: #{e.message}"
      end
    end

    private

    def merge_contexts(context)
      if context.is_a?(Context)
        context.tap { |ctx| ctx.update(@context.to_h) if @context.to_h.any? }
      elsif @context.is_a?(Context)
        @context.tap { |ctx| ctx.update(context) if context.is_a?(Hash) && context.any? }
      else
        Context.new((@context || {}).merge(context.is_a?(Hash) ? context : {}))
      end
    end

    def get_provider(options)
      provider_name = options[:provider] || self.class.provider
      config = Agents.configuration.provider_config_for(provider_name)
      Providers::Registry.get(provider_name, config)
    rescue => e
      raise ProviderError, "Failed to get provider '#{provider_name}': #{e.message}"
    end

    def build_messages(input, context)
      messages = []
      
      # Add system message
      instructions = resolve_instructions(context)
      messages << { role: "system", content: instructions } if instructions && !instructions.empty?
      
      # Add current input
      messages << { role: "user", content: input }
      
      messages
    end

    def resolve_instructions(context)
      instructions = self.class.instructions
      case instructions
      when Proc
        instructions.call(context)
      else
        instructions.to_s
      end
    end

    def build_tools
      tools = []
      
      # Add agent tools
      self.class.tools.each do |tool_class|
        tool = tool_class.is_a?(Class) ? tool_class.new : tool_class
        tool.set_context(@context) if tool.respond_to?(:set_context)
        tools << tool.to_function_schema if tool.respond_to?(:to_function_schema)
      end
      
      # Add dynamic tools (MCP tools)
      if @dynamic_tools
        @dynamic_tools.each do |dynamic_tool|
          dynamic_tool.set_context(@context) if dynamic_tool.respond_to?(:set_context)
          tools << dynamic_tool.to_function_schema if dynamic_tool.respond_to?(:to_function_schema)
        end
      end
      
      # Add handoff tools
      self.class.handoffs.each do |target_agent_class|
        handoff_tool = HandoffTool.new(target_agent_class)
        handoff_tool.set_context(@context) if handoff_tool.respond_to?(:set_context)
        tools << handoff_tool.to_function_schema
      end
      
      tools
    end

    def handle_tool_calls(tool_calls, context)
      results = []
      
      tool_calls.each do |tool_call|
        function_name = tool_call.dig("function", "name")
        arguments = JSON.parse(tool_call.dig("function", "arguments") || "{}")
        
        # Find matching tool
        tool = find_tool(function_name)
        
        if tool
          tool_trace = Agents.start_tool_trace(tool, "call", arguments)
          
          begin
            # Execute tool
            result = tool.call(**arguments.transform_keys(&:to_sym), context: context)
            tool_trace&.finish(result)
            results << "#{function_name}: #{result}"
          rescue => e
            tool_trace&.finish(e)
            puts "Tool error details: #{e.class} - #{e.message}" if ENV['DEBUG']
            puts "Tool: #{tool.inspect}" if ENV['DEBUG']
            puts "Arguments: #{arguments.inspect}" if ENV['DEBUG']
            results << "#{function_name} error: #{e.message}"
          end
        else
          results << "Unknown tool: #{function_name}"
        end
      end
      
      results.join("\n\n")
    end

    def find_tool(function_name)
      # Check agent tools
      self.class.tools.each do |tool_class|
        tool = tool_class.is_a?(Class) ? tool_class.new : tool_class
        return tool if tool.class.name.downcase.include?(function_name) || 
                      (tool.respond_to?(:tool_name) && tool.tool_name == function_name)
      end
      
      # Check dynamic tools (MCP tools)
      if @dynamic_tools
        @dynamic_tools.each do |dynamic_tool|
          return dynamic_tool if dynamic_tool.mcp_tool_name == function_name
        end
      end
      
      # Check handoff tools
      self.class.handoffs.each do |target_agent_class|
        class_name = target_agent_class.to_s.split('::').last.gsub(/Agent$/, '')
        expected_name = "transfer_to_#{class_name.downcase}"
        return HandoffTool.new(target_agent_class) if function_name == expected_name
      end
      
      nil
    end

    def detect_handoff(context)
      return nil unless context.is_a?(Context)
      
      pending_handoff = context[:pending_handoff]
      return nil unless pending_handoff
      
      HandoffResult.new(
        target_agent_class: pending_handoff[:target_agent_class],
        reason: pending_handoff[:reason]
      )
    end
  end

  # Response object returned by agents
  class AgentResponse
    attr_reader :content, :handoff_result

    def initialize(content:, handoff_result: nil)
      @content = content
      @handoff_result = handoff_result
    end

    def handoff?
      !@handoff_result.nil?
    end

    def to_s
      @content
    end
  end
end