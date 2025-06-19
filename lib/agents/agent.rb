# frozen_string_literal: true

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

    class << self
      attr_reader :agent_name, :agent_instructions, :agent_provider, :agent_model, :agent_tools

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
      # Handle context merging based on type
      execution_context = if @context.is_a?(Agents::Context)
                            @context.tap { |ctx| ctx.update(context) if context.any? }
                          else
                            @context.merge(context)
                          end

      # Resolve instructions (may be dynamic)
      resolved_instructions = resolve_instructions(execution_context)

      # Get tools for this agent
      agent_tools = instantiate_tools

      # Add handoff tools (converted at runtime like OpenAI SDK)
      handoff_tools = create_handoff_tools
      all_tools = agent_tools + handoff_tools

      # Create RubyLLM chat session
      chat = create_chat_session(execution_context, **options)

      # Set system instructions if we have them
      chat.with_instructions(resolved_instructions) if resolved_instructions && !resolved_instructions.empty?

      # Add tools to chat session
      all_tools.each { |tool| chat.with_tool(tool) }

      # Restore conversation history to chat session
      restore_conversation_history(chat)

      # Clear any previous handoff signal
      @context[:pending_handoff] = nil if @context.is_a?(Agents::Context)

      # Get response
      response = chat.ask(input)

      # Check for handoffs from context (tools signal handoffs here)
      handoff_result = detect_handoff_from_context

      # Store conversation history
      store_conversation(input, response.content)

      # Return AgentResponse with content and optional handoff
      Agents::AgentResponse.new(
        content: response.content,
        handoff_result: handoff_result
      )
    rescue StandardError => e
      handle_error(e, input, execution_context)
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

    private

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

    # Store conversation turn in history
    # @param user_input [String] User input
    # @param assistant_response [String] Assistant response
    def store_conversation(user_input, assistant_response)
      @conversation_history << {
        user: user_input,
        assistant: assistant_response,
        timestamp: Time.now
      }
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
