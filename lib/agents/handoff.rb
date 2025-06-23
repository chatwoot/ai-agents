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

  # Represents an agent response that may include content, tool calls, and handoffs.
  # This enhanced version tracks tool calls separately from conversational content,
  # allowing the Runner to properly handle handoffs as tool executions.
  class AgentResponse
    # @return [String, nil] The conversational content from the agent
    attr_reader :content

    # @return [HandoffResult, nil] Information about a requested handoff
    attr_reader :handoff_result

    # @return [Array<Hash>] Tool calls made by the agent
    attr_reader :tool_calls

    # Initialize a new agent response
    # @param content [String, nil] Conversational content (can be nil if only tool calls)
    # @param handoff_result [HandoffResult, nil] Handoff information if applicable
    # @param tool_calls [Array<Hash>] Array of tool call information
    def initialize(content: nil, handoff_result: nil, tool_calls: [])
      @content = content
      @handoff_result = handoff_result
      @tool_calls = tool_calls || []
    end

    # Check if this response includes a handoff
    # @return [Boolean] True if a handoff is requested
    def handoff?
      @handoff_result&.handoff?
    end

    # Check if this response includes tool calls
    # @return [Boolean] True if tool calls were made
    def has_tool_calls?
      !@tool_calls.empty?
    end

    # Check if this response has any conversational content
    # @return [Boolean] True if there's non-empty content
    def has_content?
      !@content.nil? && !@content.strip.empty?
    end
  end

  # A single handoff tool that can transfer to any target agent.
  # HandoffTools are special tools that signal agent transitions. Unlike regular tools
  # that return simple values, HandoffTools return structured data that allows the
  # Runner to properly track handoffs as tool calls rather than conversation content.
  class HandoffTool < Tool
    description "Transfer to another agent"
    param :reason, type: "string", desc: "Reason for the transfer (optional)", required: false

    # @return [Class] The target agent class for this handoff
    attr_reader :target_agent_class

    # Initialize a new handoff tool
    # @param target_agent_class [Class] The agent class to transfer to
    # @param description [String, nil] Custom description for this handoff
    def initialize(target_agent_class, description: nil)
      @target_agent_class = target_agent_class
      # Use the actual Ruby class name, not the agent display name
      ruby_class_name = target_agent_class.to_s.split("::").last
      @tool_name = "transfer_to_#{ruby_class_name.underscore}"
      @tool_description = description || "Transfer to #{target_agent_class.name}"

      super()
    end

    # @return [String] The tool name (e.g., "transfer_to_faq_agent")
    def name
      @tool_name
    end

    # @return [String] The tool description
    def description
      @tool_description
    end

    # Execute the handoff, returning structured data instead of a simple message.
    # This allows the Runner to identify handoffs and handle them appropriately.
    #
    # @param context [Agents::Context] The execution context
    # @param reason [String, nil] Optional reason for the handoff
    # @return [Hash] Structured handoff data with type, target, and message
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

      # Return structured response indicating this is a handoff
      # This allows the Runner to identify it as a handoff vs regular tool output
      reason_text = reason ? " (#{reason})" : ""
      {
        type: "handoff",
        target: @target_agent_class.name,
        target_class: @target_agent_class,
        reason: reason,
        message: "Transferring to #{@target_agent_class.name}#{reason_text}..."
      }
    end

    private

    # Hook for executing handoff-specific logic
    # Override in subclasses if needed
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
