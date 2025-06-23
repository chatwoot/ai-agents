# frozen_string_literal: true

# Handoff mechanism - enables seamless transitions between specialized agents
# This file defines the core handoff infrastructure that allows agents to transfer
# conversations to other agents based on context or user needs. HandoffTools are generated
# dynamically at runtime for each agent based on its declared handoffs, ensuring type safety
# and preventing circular dependencies. The handoff is signaled through shared context rather
# than return values, allowing the conversation flow to remain natural and uninterrupted.

module Agents
  # Represents a handoff result from one agent to another
  class HandoffResult
    attr_reader :target_agent_class, :reason, :context

    def initialize(target_agent_class:, reason: nil, context: nil)
      @target_agent_class = target_agent_class
      @reason = reason
      @context = context
    end

    def handoff?
      !@target_agent_class.nil?
    end
  end

  # Represents an agent response that may include a handoff
  class AgentResponse
    attr_reader :content, :handoff_result

    def initialize(content:, handoff_result: nil)
      @content = content
      @handoff_result = handoff_result
    end

    def handoff?
      @handoff_result&.handoff?
    end
  end

  # A single handoff tool that can transfer to any target agent
  class HandoffTool < Tool
    description "Transfer to another agent"
    param :reason, type: "string", desc: "Reason for the transfer (optional)", required: false

    attr_reader :target_agent_class

    def initialize(target_agent_class, description: nil)
      @target_agent_class = target_agent_class
      # Use the actual Ruby class name, not the agent display name
      ruby_class_name = target_agent_class.to_s.split("::").last
      @tool_name = "transfer_to_#{ruby_class_name.underscore}"
      @tool_description = description || "Transfer to #{target_agent_class.name}"

      super()
    end

    def name
      @tool_name
    end

    def description
      @tool_description
    end

    # Called by Agents::Tool.execute() with context injected
    def perform(context:, reason: nil)
      # Signal handoff through the existing context system
      if context
        context[:pending_handoff] = {
          target_agent_class: @target_agent_class,
          reason: reason
        }

        # Execute any handoff hooks
        execute_handoff_hook(context)

        # Record the handoff in context
        context[:last_handoff] = {
          target: @target_agent_class.name,
          reason: reason,
          timestamp: Time.now
        }
      end

      # Return transfer confirmation message (like OpenAI SDK)
      reason_text = reason ? " (#{reason})" : ""
      "Transferring to #{@target_agent_class.name}#{reason_text}..."
    end

    private

    def execute_handoff_hook(context)
      # Generic handoff hook - override in subclasses if needed
    end
  end
end

# Helper method to convert class names to underscore format
class String
  def underscore
    gsub(/::/, "/")
      .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
      .gsub(/([a-z\d])([A-Z])/, '\1_\2')
      .tr("-", "_")
      .downcase
  end
end
