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
    # @param context [Hash] Initial context for the agent
    def initialize(context: {})
      @context = context
      @conversation_history = []
    end

    # Main callable interface for the agent
    # @param input [String] The user input
    # @param context [Hash] Additional context
    # @return [String] The agent's response
    def call(input, context: {}, **options)
      # Merge context
      execution_context = @context.merge(context)

      # Resolve instructions (may be dynamic)
      resolved_instructions = resolve_instructions(execution_context)

      # Build messages for the conversation
      messages = build_messages(resolved_instructions, input)

      # Get tools for this agent
      agent_tools = instantiate_tools

      # Call RubyLLM with tools
      chat = create_chat_session(execution_context, **options)

      # Add tools to chat session
      agent_tools.each { |tool| chat.with_tool(tool) }

      # Get response
      response = chat.ask(messages)

      # Store conversation history
      store_conversation(input, response.content)

      response.content
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

    # Build messages array for RubyLLM
    # @param instructions [String] System instructions
    # @param input [String] User input
    # @return [Array<Hash>] Messages array
    def build_messages(instructions, input)
      messages = []

      # Add system message if we have instructions
      messages << { role: "system", content: instructions } if instructions && !instructions.empty?

      # Add conversation history
      @conversation_history.each do |turn|
        messages << { role: "user", content: turn[:user] }
        messages << { role: "assistant", content: turn[:assistant] }
      end

      # Add current user input
      messages << { role: "user", content: input }

      messages
    end

    # Create RubyLLM chat session
    # @param context [Hash] Execution context
    # @param options [Hash] Additional options
    # @return [RubyLLM::Chat] Chat session
    def create_chat_session(_context, **options)
      chat_options = {
        model: options[:model] || self.class.model
      }

      # Add provider-specific options
      case self.class.provider
      when :openai
        chat_options[:provider] = :openai
      when :anthropic
        chat_options[:provider] = :anthropic
      when :gemini
        chat_options[:provider] = :gemini
      end

      RubyLLM.chat(**chat_options)
    end

    # Instantiate all tools for this agent
    # @return [Array<Agents::Tool>] Array of tool instances
    def instantiate_tools
      self.class.tools.map(&:new)
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
