# frozen_string_literal: true

require "set"

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
    # @param mcp_clients [Array<Hash>, Hash, nil] MCP client configurations to add
    def initialize(name:, instructions: nil, model: "gpt-4.1-mini", tools: [], handoff_agents: [], mcp_clients: nil)
      @name = name
      @instructions = instructions
      @model = model
      @tools = tools.dup
      @handoff_agents = []
      @mcp_manager = nil

      # Mutex for thread-safe handoff registration and MCP client management
      # While agents are typically configured at startup, we want to ensure
      # that concurrent handoff registrations don't result in lost data.
      # For example, in a web server with multiple threads initializing
      # different parts of the system, we might have:
      #   Thread 1: triage.register_handoffs(billing)
      #   Thread 2: triage.register_handoffs(support)
      # Without synchronization, one registration could overwrite the other.
      @mutex = Mutex.new

      # Register initial handoff agents if provided
      register_handoffs(*handoff_agents) unless handoff_agents.empty?

      # Add MCP clients if provided
      add_mcp_clients(mcp_clients) if mcp_clients
    end

    # Get all tools available to this agent, including any auto-generated handoff tools
    #
    # @return [Array<Agents::Tool>] All tools available to the agent
    def all_tools
      @mutex.synchronize do
        # Compute handoff tools dynamically
        handoff_tools = @handoff_agents.map { |agent| HandoffTool.new(agent) }

        # Cache MCP tools to avoid repeated fetching which causes subprocess spawning
        @cached_mcp_tools ||= @mcp_manager ? @mcp_manager.get_agent_tools : []

        @tools + handoff_tools + @cached_mcp_tools
      end
    end

    # Register agents that this agent can hand off to.
    # This method can be called after agent creation to set up handoff relationships.
    # Thread-safe: Multiple threads can safely call this method concurrently.
    #
    # @param agents [Array<Agents::Agent>] Agents to register as handoff targets
    # @return [self] Returns self for method chaining
    # @example Setting up hub-and-spoke pattern
    #   # Create agents
    #   triage = Agent.new(name: "Triage", instructions: "Route to specialists")
    #   billing = Agent.new(name: "Billing", instructions: "Handle payments")
    #   support = Agent.new(name: "Support", instructions: "Fix technical issues")
    #
    #   # Wire up handoffs after creation - much cleaner than complex factories!
    #   triage.register_handoffs(billing, support)
    #   billing.register_handoffs(triage)  # Specialists only handoff back to triage
    #   support.register_handoffs(triage)
    def register_handoffs(*agents)
      @mutex.synchronize do
        @handoff_agents.concat(agents)
        @handoff_agents.uniq! # Prevent duplicates
      end
      self
    end

    # Add MCP clients to this agent using configurations
    #
    # @param client_configs [Hash, Array<Hash>] Client configuration(s) to add
    # @return [self] Returns self for method chaining
    # @example Adding MCP clients
    #   agent.add_mcp_clients({
    #     name: "filesystem",
    #     command: "npx",
    #     args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
    #   })
    #
    #   # Or add multiple clients
    #   agent.add_mcp_clients([
    #     { name: "filesystem", command: "npx", args: ["fs-server"] },
    #     { name: "api", url: "http://localhost:8000" }
    #   ])
    def add_mcp_clients(client_configs)
      configs_array = Array(client_configs)

      @mutex.synchronize do
        # Initialize MCP manager if not exists
        @mcp_manager ||= MCP::Manager.new(
          enable_fallback_mode: true,
          handle_collisions: :prefix
        )

        # Add each client configuration
        configs_array.each do |config|
          add_mcp_client(config)
        end
      end

      self
    end

    # Add a single MCP client to this agent
    #
    # @param config [Hash] The MCP client configuration
    # @return [self] Returns self for method chaining
    def add_mcp_client(config)
      # Initialize MCP manager if not exists
      @mcp_manager ||= MCP::Manager.new(
        enable_fallback_mode: true,
        handle_collisions: :prefix
      )

      # Add client to manager
      begin
        @mcp_manager.add_client(**config)
      rescue StandardError => e
        warn "Failed to add MCP client '#{config[:name]}': #{e.message}"
        # Continue without this client rather than failing entirely
      end

      self
    end

    # Refresh MCP tools by reconnecting to all clients and reloading their tools
    # This can be used if MCP servers have updated their available tools
    #
    # @return [self] Returns self for method chaining
    def refresh_mcp_tools
      @mutex.synchronize do
        if @mcp_manager
          @mcp_manager.refresh_all_clients
          # Clear cached tools so they'll be re-fetched on next all_tools call
          @cached_mcp_tools = nil
        end
      end

      self
    end

    # Get MCP manager for this agent
    #
    # @return [Agents::MCP::Manager, nil] MCP manager or nil if no MCP clients
    def mcp_manager
      @mutex.synchronize { @mcp_manager }
    end

    # Get health status of all MCP clients
    #
    # @return [Hash] Health status by client name, or empty hash if no MCP manager
    def mcp_client_health
      @mutex.synchronize do
        @mcp_manager ? @mcp_manager.client_health_status : {}
      end
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
    # @option changes [Array<Agents::MCP::Client>] :mcp_clients New MCP clients
    # @return [Agents::Agent] A new frozen agent instance with the specified changes
    def clone(**changes)
      # Filter out MCP tools from current tools if we're providing new MCP clients
      base_tools = if changes.key?(:mcp_clients)
                     @tools.reject { |tool| tool.is_a?(MCP::Tool) }
                   else
                     @tools.dup
                   end

      self.class.new(
        name: changes.fetch(:name, @name),
        instructions: changes.fetch(:instructions, @instructions),
        model: changes.fetch(:model, @model),
        tools: changes.fetch(:tools, base_tools),
        handoff_agents: changes.fetch(:handoff_agents, @handoff_agents),
        mcp_clients: changes.fetch(:mcp_clients, changes.key?(:mcp_clients) ? nil : @mcp_clients)
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
