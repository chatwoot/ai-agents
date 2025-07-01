# frozen_string_literal: true

module Agents
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
  # ## First-Call-Wins Implementation
  # This implementation uses "first-call-wins" semantics to prevent infinite handoff loops.
  #
  # ### The Problem We Solved
  # During development, we discovered that LLMs could call the same handoff tool multiple times
  # in a single response, leading to infinite loops:
  #
  # 1. User: "My internet isn't working but my account shows active"
  # 2. Triage Agent hands off to Support Agent
  # 3. Support Agent sees account info is needed, hands back to Triage Agent
  # 4. Triage Agent sees technical issue, hands off to Support Agent again
  # 5. This creates an infinite ping-pong loop
  #
  # ### Root Cause Analysis
  # Unlike OpenAI's SDK which processes tool calls before execution, RubyLLM automatically
  # executes all tool calls in a response. This meant:
  # - LLM calls handoff tool 10+ times in one response
  # - Each call sets context[:pending_handoff], overwriting previous values
  # - Runner processes handoffs after tool execution, seeing only the last one
  # - Multiple handoff signals created conflicting state
  #
  # TODO: Overall, this problem can be tackled better if we replace the RubyLLM chat
  # program with our own implementation.
  #
  # ### The Solution
  # We implemented first-call-wins semantics inspired by OpenAI's approach:
  # - First handoff call in a response sets the pending handoff
  # - Subsequent calls are ignored with a "transfer in progress" message
  # - This prevents loops and mirrors OpenAI SDK behavior
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
  # @example First-call-wins in action
  #   # Single LLM response with multiple handoff calls:
  #   # Call 1: handoff_to_support() -> Sets pending_handoff, returns "Transferring to Support"
  #   # Call 2: handoff_to_support() -> Ignored, returns "Transfer already in progress"
  #   # Call 3: handoff_to_billing() -> Ignored, returns "Transfer already in progress"
  #   # Result: Only transfers to Support Agent (first call wins)
  class HandoffTool < Tool
    attr_reader :target_agent

    def initialize(target_agent)
      @target_agent = target_agent

      # Set up the tool with a standardized name and description
      @tool_name = "handoff_to_#{target_agent.name.downcase.gsub(/\s+/, "_")}"
      @tool_description = "Transfer conversation to #{target_agent.name}"

      # Don't call super() - let RubyLLM handle the initialization
    end

    # Override the auto-generated name to use our specific name
    def name
      @tool_name
    end

    # Override the description
    def description
      @tool_description
    end

    # Handoff tools don't need parameters - just the intent to transfer
    def perform(tool_context, **params)
      if tool_context.context[:pending_handoff]
        return "Transfer request noted (already processing a handoff). Please wait for the current handoff to complete."
      end

      # Extract message parameter
      message = params[:message] || "Handoff initiated"

      # Store handoff information in context for Runner to process
      tool_context.context[:pending_handoff] = {
        agent: @target_agent,
        message: message
      }

      handoff_response = "I'm transferring you to #{@target_agent.name}. #{message}"
      Agents.logger.debug "Handoff signaled, returning message: #{handoff_response}"

      handoff_response
    end

    # Return empty parameters hash since handoff tools don't take any parameters
    def parameters
      {}
    end
  end
end
