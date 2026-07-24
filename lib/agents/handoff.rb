# frozen_string_literal: true

module Agents
  # Defines a handoff relationship between two agents.
  #
  # A relationship may customize the tool presented to the model and run a hook
  # after the handoff is accepted. The default behavior remains HandoffTool with
  # no parameters, preserving compatibility with register_handoffs.
  class Handoff
    attr_reader :target_agent, :tool_factory, :on_handoff

    def initialize(target_agent, tool_factory: nil, on_handoff: nil)
      validate_callable(:tool_factory, tool_factory)
      validate_callable(:on_handoff, on_handoff)

      @target_agent = target_agent
      @tool_factory = tool_factory
      @on_handoff = on_handoff
      freeze
    end

    def build_tool(source_agent:)
      tool = if @tool_factory
               @tool_factory.call(source_agent: source_agent, target_agent: @target_agent)
             else
               HandoffTool.new(@target_agent)
             end

      validate_tool(tool)
      tool
    end

    def call_hook(context_wrapper, handoff_info)
      @on_handoff&.call(context_wrapper, handoff_info)
    end

    private

    def validate_callable(name, callable)
      return if callable.nil? || callable.respond_to?(:call)

      raise ArgumentError, "#{name} must respond to #call"
    end

    def validate_tool(tool)
      raise ArgumentError, "tool_factory must return an Agents::HandoffTool" unless tool.is_a?(HandoffTool)
      return if tool.target_agent.equal?(@target_agent)

      raise ArgumentError, "custom handoff tool must use the registered target agent"
    end
  end

  # A special tool that enables agents to transfer conversations to other specialized agents.
  # Handoffs are implemented as tools (following OpenAI's pattern) because this allows
  # the LLM to naturally decide when to transfer based on the conversation context.
  #
  # ## How Handoffs Work
  # 1. Agent A is configured with handoff_agents: [Agent B, Agent C]
  # 2. This automatically creates HandoffTool instances for B and C
  # 3. The LLM can call these tools like any other tool
  # 4. The tool signals the handoff through context
  # 5. The Runner detects this and switches to the new agent
  #
  # ## Concurrent Handoff Selection
  # Only one handoff may be pending at a time. The first handoff accepted by
  # RunContext wins. This does not prevent sequential handoff loops across
  # multiple agent turns.
  #
  # ## Why Tools Instead of Instructions
  # Using tools for handoffs has several advantages:
  # - LLMs reliably use tools when appropriate
  # - Clear schema tells the LLM when each handoff is suitable
  # - No parsing of free text needed
  # - Works consistently across different LLM providers
  #
  # @example Basic handoff setup
  #   billing_agent = Agent.new(name: "Billing", instructions: "Handle payments")
  #   support_agent = Agent.new(name: "Support", instructions: "Technical help")
  #
  #   triage = Agent.new(
  #     name: "Triage",
  #     instructions: "Route users to the right team",
  #     handoff_agents: [billing_agent, support_agent]
  #   )
  #   # Creates tools: handoff_to_billing, handoff_to_support
  #
  # @example How the LLM sees it
  #   # User: "I can't pay my bill"
  #   # LLM thinks: "This is a payment issue, I should transfer to billing"
  #   # LLM calls: handoff_to_billing()
  #   # Runner switches to billing_agent for the next turn
  #
  # @example Multiple handoff handling
  #   # Single LLM response with multiple handoff calls:
  #   # First handoff accepted by RunContext -> Processed and executed
  #   # Later handoff executions -> Rejected while one is pending
  #   # With concurrent execution, model emission order does not determine the winner
  class HandoffTool < Tool
    attr_reader :target_agent

    def initialize(target_agent, name: nil, description: nil)
      @target_agent = target_agent

      # Set up the tool with a standardized name and description
      @tool_name = name || "handoff_to_#{Helpers::NameNormalizer.to_tool_name(target_agent.name)}"
      @tool_description = description || self.class.description || "Transfer conversation to #{target_agent.name}"

      super()
    end

    # Override the auto-generated name to use our specific name
    def name
      @tool_name
    end

    # Override the description
    def description
      @tool_description
    end

    # Use RubyLLM's halt mechanism to stop continuation after handoff
    # Store handoff info in context for Runner to detect and process
    def perform(tool_context)
      prepare_handoff(tool_context)
    end

    # NOTE: RubyLLM will handle schema generation internally when needed
    # Handoff tools have no parameters, which RubyLLM will detect automatically

    protected

    # Accept a handoff with optional operational data.
    # Subclasses can expose their own parameter schema and pass the resulting
    # values here without changing Runner internals.
    def prepare_handoff(tool_context, reason: nil, metadata: nil, message: nil)
      handoff_info = {
        target_agent: @target_agent,
        timestamp: Time.now
      }
      handoff_info[:reason] = reason unless reason.nil?
      handoff_info[:metadata] = metadata unless metadata.nil?

      accepted = tool_context.run_context.prepare_handoff(handoff_info)
      return "A handoff is already pending; no additional handoff was created." unless accepted

      halt(message || "I'll transfer you to #{@target_agent.name} who can better assist you with this.")
    end
  end
end
