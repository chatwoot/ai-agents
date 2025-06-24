# frozen_string_literal: true

# The core agent definition that represents an AI assistant with specific capabilities.
# Agents are immutable, thread-safe objects that can be cloned with modifications.
# They encapsulate the configuration needed to interact with an LLM including
# instructions, tools, and potential handoff targets.
#
# @example Creating a basic agent
#   agent = Agents::Agent.new(
#     name: "Assistant",
#     instructions: "You are a helpful assistant",
#     model: "gpt-4",
#     tools: [calculator_tool, weather_tool]
#   )
#
# @example Creating an agent with dynamic instructions
#   agent = Agents::Agent.new(
#     name: "Support Agent",
#     instructions: ->(context) {
#       "You are supporting user #{context.context[:user_name]}"
#     }
#   )
#
# @example Cloning an agent with modifications
#   specialized_agent = base_agent.clone(
#     instructions: "You are a specialized assistant",
#     tools: base_agent.tools + [new_tool]
#   )
module Agents
  class Agent
    attr_reader :name, :instructions, :model, :tools, :handoff_agents

    # Initialize a new Agent instance
    #
    # @param name [String] The name of the agent
    # @param instructions [String, Proc, nil] Static string or dynamic Proc that returns instructions
    # @param model [String] The LLM model to use (default: "gpt-4.1-mini")
    # @param tools [Array<Agents::Tool>] Array of tool instances the agent can use
    # @param handoff_agents [Array<Agents::Agent>] Array of agents this agent can hand off to
    def initialize(name:, instructions: nil, model: "gpt-4.1-mini", tools: [], handoff_agents: [])
      @name = name
      @instructions = instructions
      @model = model
      @tools = tools.dup
      @handoff_agents = handoff_agents

      # Automatically create handoff tools
      # TODO: Enable this once we have the complete implementation for HandoffTool
      # @handoff_agents.each do |agent|
      #   @tools << HandoffTool.new(agent: agent)
      # end

      # Freeze the agent to make it immutable
      freeze
    end

    # Get all tools available to this agent, including any auto-generated handoff tools
    #
    # @return [Array<Agents::Tool>] All tools available to the agent
    def all_tools
      @tools
    end

    # Creates a new agent instance with modified attributes while preserving immutability.
    # The clone method is used when you need to create variations of agents without mutating the original.
    # This can be used for runtime agent modifications, say in a multi-tenant environment we can do something like the following:
    #
    # @example Multi-tenant agent customization
    #   def agent_for_tenant(tenant)
    #     @base_agent.clone(
    #       instructions: "You work for #{tenant.company_name}",
    #       tools: @base_agent.tools + tenant.custom_tools
    #     )
    #   end
    #
    # @example Creating specialized variants
    #   finance_writer = @writer_agent.clone(
    #     tools: @writer_agent.tools + [financial_research_tool]
    #   )
    #
    #   marketing_writer = @writer_agent.clone(
    #     tools: @writer_agent.tools + [marketing_research_tool]
    #   )
    #
    # The key insight to note here is that clone ensures immutability - you never accidentally modify a shared agent
    # instance that other requests might be using. This is critical for thread safety in concurrent
    # environments.
    #
    # This also ensures we also get to leverage the syntax sugar defining a class provides us with.
    #
    # @param changes [Hash] Keyword arguments for attributes to change
    # @option changes [String] :name New agent name
    # @option changes [String, Proc] :instructions New instructions
    # @option changes [String] :model New model identifier
    # @option changes [Array<Agents::Tool>] :tools New tools array (replaces all tools)
    # @option changes [Array<Agents::Agent>] :handoff_agents New handoff agents
    # @return [Agents::Agent] A new frozen agent instance with the specified changes
    def clone(**changes)
      self.class.new(
        name: changes.fetch(:name, @name),
        instructions: changes.fetch(:instructions, @instructions),
        model: changes.fetch(:model, @model),
        tools: changes.fetch(:tools, @tools.dup),
        handoff_agents: changes.fetch(:handoff_agents, @handoff_agents)
      )
    end

    # Get the system prompt for the agent, potentially customized based on runtime context.
    # We will allow setting up a Proc for instructions.
    # This will allow us the inject context in runtime.
    #
    # @example Static instructions (most common)
    #   agent = Agent.new(
    #     name: "Support",
    #     instructions: "You are a helpful support agent"
    #   )
    #
    # @example Dynamic instructions based on context
    #   agent = Agent.new(
    #     name: "Support",
    #     instructions: ->(context) {
    #       user = context.context[:user]
    #       "You are helping #{user.name}. They are a #{user.tier} customer with account #{user.id}"
    #     }
    #   )
    #
    # @param context [Agents::RunContext] The current execution context containing runtime data
    # @return [String, nil] The system prompt string or nil if no instructions are set
    def get_system_prompt(context)
      case instructions
      when String
        instructions
      when Proc
        instructions.call(context)
      end
    end
  end
end
