# frozen_string_literal: true

module Agents
  # Represents a handoff result from one agent to another
  class HandoffResult
    attr_reader :target_agent_class, :reason

    def initialize(target_agent_class:, reason: nil)
      @target_agent_class = target_agent_class
      @reason = reason
    end

    def handoff?
      !@target_agent_class.nil?
    end
  end

  # A handoff tool that can transfer to a target agent  
  class HandoffTool < ToolBase
    attr_reader :target_agent_class

    def initialize(target_agent_class, description: nil)
      @target_agent_class = target_agent_class
      # Sanitize the tool name to match OpenAI pattern ^[a-zA-Z0-9_-]+$
      # Use actual class name (via .to_s), not the agent's display name
      class_name = target_agent_class.to_s.split('::').last.gsub(/Agent$/, '')
      @tool_name = "transfer_to_#{class_name.downcase}"
      @tool_description = description || "Transfer to #{target_agent_class.to_s}"
      super()
    end

    # Override ToolBase methods to provide dynamic values
    def self.name
      "dynamic_handoff_tool"
    end

    def self.description  
      "Dynamic handoff tool"
    end

    # Instance methods that provide the actual tool metadata
    def tool_name
      @tool_name
    end

    def tool_description
      @tool_description
    end

    # Generate function schema for OpenAI function calling
    def to_function_schema
      {
        type: "function",
        function: {
          name: @tool_name,
          description: @tool_description,
          parameters: {
            type: "object",
            properties: {
              reason: {
                type: "string",
                description: "Reason for the transfer (optional)"
              }
            },
            required: []
          }
        }
      }
    end

    # Execute the handoff
    def call(**kwargs)
      reason = kwargs[:reason]
      context = kwargs[:context]
      perform(context: context, reason: reason)
    end

    # Called by the tool system with context injected
    def perform(context: nil, reason: nil)
      # Start handoff trace
      source_agent_class = context&.dig(:current_agent_class) || Object
      handoff_trace = Agents.start_handoff_trace(
        source_agent_class,
        @target_agent_class,
        reason,
        context
      )

      begin
        # Signal handoff through the context system
        if context
          context[:pending_handoff] = {
            target_agent_class: @target_agent_class,
            reason: reason
          }

          # Record the handoff in context
          context[:last_handoff] = {
            target: @target_agent_class.name,
            reason: reason,
            timestamp: Time.now
          }
        end

        # Return transfer confirmation message
        reason_text = reason ? " (#{reason})" : ""
        result = "Transferring to #{@target_agent_class.name}#{reason_text}..."
        
        # Finish handoff trace
        handoff_trace&.finish(result)
        
        result
      rescue => e
        # Finish handoff trace with error
        handoff_trace&.finish(e)
        raise HandoffError, "Handoff failed: #{e.message}"
      end
    end
  end
end