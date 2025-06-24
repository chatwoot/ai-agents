# frozen_string_literal: true

# The core agent definition.

class Agents::Agent
  attr_reader :name, :instructions, :model, :tools, :handoff_agents

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

  def all_tools
    @tools
  end

  # The clone method is used when you need to create variations of agents without mutating the original
  # This can be used for runtime agent modifications, say in a multi-tenant environment we can do something like the following
  #
  # def agent_for_tenant(tenant)
  #   @base_agent.clone(
  #     instructions: "You work for #{tenant.company_name}",
  #     tools: @base_agent.tools + tenant.custom_tools
  #   )
  # end
  #
  # or make agents with separate features but the same base prompt
  #
  # finance_write = @writer_agent.clone(
  #   tools: @writer_agent.tools + [financial_research_tool]
  # )
  #
  # marketing_write = @writer_agent.clone(
  #   tools: @writer_agent.tools + [marketing_research_tool]
  # )
  #
  # The key insight to note here is that clone ensures immutability - you never accidentally modify a shared agent
  # instance that other requests might be using. This is critical for thread safety in concurrent
  # environments.
  #
  # This also ensures we also get to leverage the syntax sugar defining a class provides us with.
  def clone(**changes)
    self.class.new(
      name: changes.fetch(:name, @name),
      instructions: changes.fetch(:instructions, @instructions),
      model: changes.fetch(:model, @model),
      tools: changes.fetch(:tools, @tools.dup),
      handoff_agents: changes.fetch(:handoff_agents, @handoff_agents)
    )
  end

  # We will allow setting up a Proc for instructions
  # This will allow us the inject context in runtime
  #
  # --- Static instructions (most common) ---
  # agent = Agent.new(
  #   name: "Support",
  #   instructions: "You are a helpful support agent"
  # )
  #
  # --- Dynamic instructions based on context ---
  # agent = Agent.new(
  #   name: "Support",
  #   instructions: ->(context, agent) {
  #     user = context.context[:user]
  #     "You are helping #{user.name}. They are a #{user.tier} customer with account #{user.id}"
  #   }
  # )
  def get_system_prompt(context)
    case instructions
    when String
      instructions
    when Proc
      instructions.call(context)
    else
      nil
    end
  end
end
