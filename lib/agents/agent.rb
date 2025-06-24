# frozen_string_literal: true

# Core Agent class - the fundamental building block of the multi-agent system
# This class provides the base implementation for creating AI agents with specific behaviors.
# Agents maintain their own conversation context, can use tools to perform actions,
# enforce input/output guardrails for safety, and seamlessly hand off conversations
# to other specialized agents when needed. The DSL makes it easy to define agents declaratively.

# Base class for AI agents with Ruby-like DSL and RubyLLM integration.
# Agents can use tools, have conversations, and be composed together.
#
# @example Define a simple agent
#   class WeatherAgent < Agents::Agent
#     name "Weather Assistant"
#     instructions "Help users get weather information"
#     provider :openai
#
#     uses WeatherTool
#   end
#
# @example Use an agent
#   agent = WeatherAgent.new
#   result = agent.call("What's the weather in Tokyo?")
module Agents
  class Agent
    # Agent execution errors
    class ExecutionError < Agents::Error; end
    class ToolNotFoundError < ExecutionError; end
    class MaxTurnsExceededError < ExecutionError; end
    class InputGuardrailTripwireTriggered < ExecutionError; end
    class OutputGuardrailTripwireTriggered < ExecutionError; end

    class << self
      attr_reader :agent_name, :agent_instructions, :agent_provider, :agent_model, :agent_tools,
                  :agent_input_guardrails, :agent_output_guardrails, :agent_mcp_clients

      # Set or get the agent name
      # @param value [String, nil] The name to set
      # @return [String] The current name
      def name(value = nil)
        @agent_name = value if value
        @agent_name || to_s.split("::").last.gsub(/Agent$/, "")
      end

      # Set or get the agent instructions
      # @param value [String, Proc, nil] The instructions to set
      # @return [String, Proc] The current instructions
      def instructions(value = nil)
        @agent_instructions = value if value
        @agent_instructions || "You are a helpful AI assistant."
      end

      # Set or get the provider
      # @param value [Symbol, nil] The provider to set (:openai, :anthropic, etc.)
      # @return [Symbol] The current provider
      def provider(value = nil)
        @agent_provider = value if value
        @agent_provider || Agents.configuration.default_provider
      end

      # Set or get the model
      # @param value [String, nil] The model to set
      # @return [String] The current model
      def model(value = nil)
        @agent_model = value if value
        @agent_model || Agents.configuration.default_model
      end

      # Register a tool class for this agent
      # @param tool_class [Class] Tool class that extends Agents::Tool
      def uses(tool_class)
        @agent_tools ||= []
        @agent_tools << tool_class unless @agent_tools.include?(tool_class)
      end

      # Get all registered tools
      # @return [Array<Class>] Array of tool classes
      def tools
        @agent_tools || []
      end

      # Define possible handoff targets for this agent
      # @param targets [Array<Class>] Agent classes this agent can hand off to
      def handoffs(*targets)
        return @handoff_targets ||= [] if targets.empty?

        @handoff_targets = targets.flatten
      end

      # Register input guardrails for this agent
      # @param guardrails [Array<InputGuardrail>] Input guardrails to register
      def input_guardrails(*guardrails)
        @agent_input_guardrails ||= []
        @agent_input_guardrails.concat(guardrails.flatten)
      end

      # Register output guardrails for this agent
      # @param guardrails [Array<OutputGuardrail>] Output guardrails to register
      def output_guardrails(*guardrails)
        @agent_output_guardrails ||= []
        @agent_output_guardrails.concat(guardrails.flatten)
      end

      # Get all input guardrails
      # @return [Array<InputGuardrail>] Array of input guardrails
      def get_input_guardrails
        (@agent_input_guardrails || []).map do |guardrail|
          guardrail.is_a?(Class) ? guardrail.new : guardrail
        end
      end

      # Get all output guardrails
      # @return [Array<OutputGuardrail>] Array of output guardrails
      def get_output_guardrails
        (@agent_output_guardrails || []).map do |guardrail|
          guardrail.is_a?(Class) ? guardrail.new : guardrail
        end
      end

      # Register MCP clients for this agent
      # @param clients [Array<Agents::MCP::Client>] MCP clients to register
      def mcp_clients(*clients)
        @agent_mcp_clients ||= []
        @agent_mcp_clients.concat(clients.flatten)
      end

      # Get all registered MCP clients
      # @return [Array<Agents::MCP::Client>] Array of MCP clients
      def get_mcp_clients
        @agent_mcp_clients || []
      end

      # Create and call agent in one step (class-level callable interface)
      # @param input [String] The input message
      # @param context [Hash] Additional context
      # @return [String] The agent's response
      def call(input, context: {}, **options)
        new.call(input, context: context, **options)
      end

      # Enable symbol-to-proc conversion: topics.map(&AgentClass)
      # @return [Proc] Proc that creates and calls agent
      def to_proc
        method(:call).to_proc
      end
    end

    # Instance methods

    # Initialize a new agent instance
    # @param context [Hash, Agents::Context] Initial context for the agent
    def initialize(context: {})
      @context = context.is_a?(Agents::Context) ? context : Agents::Context.new(context)
      @conversation_history = []
    end

    # Main callable interface for the agent
    # @param input [String] The user input
    # @param context [Hash] Additional context
    # @return [Agents::AgentResponse] The agent's response with optional handoff
    def call(input, context: {}, **options)
      # Wrap agent execution in a span
      Agents::Tracing.with_span(
        name: "Agent:#{self.class.name}",
        category: :agent,
        metadata: agent_span_metadata(input, context, options)
      ) do
        call_with_tracing(input, context: context, **options)
      end
    end

    private

    # Internal call method with tracing context established
    # @param input [String] The user input
    # @param context [Hash] Additional context
    # @return [Agents::AgentResponse] The agent's response with optional handoff
    def call_with_tracing(input, context: {}, **options)
      # Merge contexts appropriately
      execution_context = merge_contexts(@context, context)

      # Resolve instructions (may be dynamic)
      resolved_instructions = resolve_instructions(execution_context)

      # Get tools for this agent
      agent_tools = instantiate_tools

      # Get MCP tools from configured clients
      mcp_tools = instantiate_mcp_tools

      # Add handoff tools (converted at runtime like OpenAI SDK)
      handoff_tools = create_handoff_tools
      all_tools = agent_tools + mcp_tools + handoff_tools

      # Create RubyLLM chat session
      chat = create_chat_session(execution_context, **options)

      # Set system instructions if we have them
      chat.with_instructions(resolved_instructions) if resolved_instructions && !resolved_instructions.empty?

      # Add tools to chat session
      all_tools.each { |tool| chat.with_tool(tool) }

      # Restore conversation history to chat session (Runner manages this)
      restore_conversation_history(chat)

      # Clear any previous handoff signal
      @context[:pending_handoff] = nil if @context.is_a?(Agents::Context)

      # Run input guardrails
      input_guardrail_violation = check_input_guardrails(execution_context, input)
      if input_guardrail_violation
        return Agents::AgentResponse.new(
          content: input_guardrail_violation,
          handoff_result: nil
        )
      end

      # Get response from LLM with tracing
      response = Agents::Tracing.with_span(
        name: "LLM:#{self.class.model}",
        category: :llm,
        metadata: llm_span_metadata(input, resolved_instructions)
      ) do
        chat.ask(input)
      end

      # Run output guardrails
      output_guardrail_violation = check_output_guardrails(execution_context, response.content)
      if output_guardrail_violation
        return Agents::AgentResponse.new(
          content: output_guardrail_violation,
          handoff_result: nil
        )
      end

      # Check for handoffs from context (tools signal handoffs here)
      handoff_result = detect_handoff_from_context

      # Return AgentResponse with content and optional handoff
      # Note: Runner handles conversation history, not individual agents
      Agents::AgentResponse.new(
        content: response.content,
        handoff_result: handoff_result
      )
    rescue StandardError => e
      handle_error(e, input, execution_context)
    end

    # Generate metadata for agent span
    # @param input [String] User input
    # @param context [Hash] Additional context
    # @param options [Hash] Additional options
    # @return [Hash] Agent span metadata
    def agent_span_metadata(input, _context, _options)
      metadata = {
        agent_name: self.class.name,
        agent_provider: self.class.provider,
        agent_model: self.class.model,
        input_length: input.length,
        tools_count: self.class.tools.length,
        mcp_clients_count: self.class.get_mcp_clients.length,
        handoff_targets: self.class.handoffs.map(&:name)
      }

      # Include input if sensitive data is allowed
      if Agents.configuration.tracing.include_sensitive_data
        metadata[:input] = input.length > 500 ? "#{input[0...500]}... [truncated]" : input
      end

      metadata
    end

    # Generate metadata for LLM span
    # @param input [String] User input
    # @param instructions [String] Resolved instructions
    # @return [Hash] LLM span metadata
    def llm_span_metadata(input, instructions)
      metadata = {
        model: self.class.model,
        provider: self.class.provider,
        input_length: input.length
      }

      if Agents.configuration.tracing.include_sensitive_data
        metadata[:input] = input.length > 300 ? "#{input[0...300]}... [truncated]" : input
        if instructions
          metadata[:instructions] = instructions.length > 200 ? "#{instructions[0...200]}... [truncated]" : instructions
        end
      end

      metadata
    end

    # Support for agent.() syntax
    alias [] call

    # Get agent metadata
    # @return [Hash] Agent metadata
    def metadata
      {
        name: self.class.name,
        instructions: self.class.instructions,
        provider: self.class.provider,
        model: self.class.model,
        tools: self.class.tools.map(&:name)
      }
    end

    # Get conversation history
    # @return [Array<Hash>] Array of conversation turns
    def history
      @conversation_history.dup
    end

    # Clear conversation history
    def clear_history!
      @conversation_history.clear
    end

    # Merge contexts based on their types
    # @param base_context [Hash, Agents::Context] The base context
    # @param new_context [Hash, Agents::Context] The context to merge in
    # @return [Hash, Agents::Context] The merged context
    def merge_contexts(base_context, new_context)
      case [base_context.class, new_context.class]
      when [Hash, Hash]
        base_context.merge(new_context)
      when [Agents::Context, Hash]
        base_context.tap { |ctx| ctx.update(new_context) if new_context.any? }
      when [Agents::Context, Agents::Context]
        base_context.tap { |ctx| ctx.update(new_context) }
      when [Hash, Agents::Context]
        new_context.tap { |ctx| ctx.update(base_context) }
      else
        # Fallback: if base_context is a Context subclass, use it; otherwise merge as hashes
        if base_context.is_a?(Agents::Context)
          base_context.tap do |ctx|
            ctx.update(new_context) if new_context.respond_to?(:update) || new_context.is_a?(Hash)
          end
        else
          base_context.merge(new_context.respond_to?(:to_h) ? new_context.to_h : new_context)
        end
      end
    end

    # Detect handoffs from context (tools signal handoffs here)
    # @return [HandoffResult, nil] Handoff result if detected
    def detect_handoff_from_context
      return nil unless @context.is_a?(Agents::Context)

      pending_handoff = @context[:pending_handoff]
      return nil unless pending_handoff

      Agents::HandoffResult.new(
        target_agent_class: pending_handoff[:target_agent_class],
        reason: pending_handoff[:reason]
      )
    end

    # Resolve instructions (handle Proc instructions)
    # @param context [Hash] Execution context
    # @return [String] Resolved instructions
    def resolve_instructions(context)
      instructions = self.class.instructions
      case instructions
      when Proc
        instructions.call(context)
      when String
        instructions
      else
        instructions.to_s
      end
    end

    # Restore conversation history to RubyLLM chat session
    # @param chat [RubyLLM::Chat] The chat session
    def restore_conversation_history(chat)
      # Restore our stored conversation history to the chat session
      @conversation_history.each do |turn|
        chat.add_message(role: :user, content: turn[:user])
        chat.add_message(role: :assistant, content: turn[:assistant])
      end
    end

    # Create RubyLLM chat session
    # @param context [Hash] Execution context
    # @param options [Hash] Additional options
    # @return [RubyLLM::Chat] Chat session
    def create_chat_session(_context, **options)
      model = options[:model] || self.class.model
      RubyLLM.chat(model: model)
    end

    # Instantiate all tools for this agent with context
    # @return [Array<Agents::Tool>] Array of tool instances
    def instantiate_tools
      tools = self.class.tools.map do |tool|
        # Handle both classes and instances
        tool.is_a?(Class) ? tool.new : tool
      end

      # Set context on all tools if we have one
      tools.each { |tool| tool.set_context(@context) } if @context.is_a?(Agents::Context)

      tools
    end

    # Instantiate MCP tools from configured clients
    # @return [Array<Agents::MCP::Tool>] Array of MCP tool instances
    def instantiate_mcp_tools
      tools = []

      self.class.get_mcp_clients.each do |mcp_client|
        # Ensure client is connected
        mcp_client.connect unless mcp_client.connected?

        # Get tools from this MCP server
        client_tools = mcp_client.list_tools
        tools.concat(client_tools)
      rescue Agents::MCP::Error => e
        # Log the error but don't fail the agent creation
        warn "Failed to load tools from MCP client '#{mcp_client.name}': #{e.message}"
      end

      # Set context on all MCP tools if we have one
      tools.each { |tool| tool.set_context(@context) } if @context.is_a?(Agents::Context)

      tools
    end

    # Create handoff tools at runtime (following OpenAI SDK pattern)
    # @return [Array<Agents::HandoffTool>] Array of handoff tool instances
    def create_handoff_tools
      self.class.handoffs.map do |target_agent_class|
        handoff_tool = Agents::HandoffTool.new(
          target_agent_class,
          description: "Transfer to #{target_agent_class.name} to handle the request"
        )
        handoff_tool.set_context(@context) if @context.is_a?(Agents::Context)
        handoff_tool
      end
    end

    # Check input guardrails and return user-friendly message if violated
    # @param context [Hash] Execution context
    # @param input [String] User input
    # @return [String, nil] Error message if guardrail violated, nil otherwise
    def check_input_guardrails(context, input)
      self.class.get_input_guardrails.each do |guardrail|
        result = guardrail.call(context, self, input)

        return generate_guardrail_response(guardrail, result.output.output_info, :input) if result.triggered?
      end
      nil
    end

    # Check output guardrails and return user-friendly message if violated
    # @param context [Hash] Execution context
    # @param agent_output [String] Agent's response
    # @return [String, nil] Error message if guardrail violated, nil otherwise
    def check_output_guardrails(context, agent_output)
      self.class.get_output_guardrails.each do |guardrail|
        result = guardrail.call(context, self, agent_output)

        return generate_guardrail_response(guardrail, result.output.output_info, :output) if result.triggered?
      end
      nil
    end

    # Generate a user-friendly response when a guardrail is violated
    # @param guardrail [InputGuardrail, OutputGuardrail] The violated guardrail
    # @param output_info [String] Additional info from the guardrail
    # @param type [Symbol] :input or :output
    # @return [String] User-friendly error message
    def generate_guardrail_response(_guardrail, output_info, type)
      case type
      when :input
        "I'm sorry, but I can't process that request. #{output_info}"
      when :output
        "I apologize, but I can't provide that response. Please try asking in a different way."
      end
    end

    # Handle errors during execution
    # @param error [Exception] The error that occurred
    # @param input [String] The input that caused the error
    # @param context [Hash] Execution context
    # @return [String] Error response
    def handle_error(error, _input, _context)
      case error
      when RubyLLM::Error
        raise ExecutionError, "LLM error: #{error.message}"
      else
        raise ExecutionError, "Agent execution failed: #{error.message}"
      end
    end
  end
end
