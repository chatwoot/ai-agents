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
    attr_reader :name, :instructions, :model, :tools, :handoff_agents, :service_name

    # Initialize a new Agent instance
    #
    # @param name [String] The name of the agent
    # @param instructions [String, Proc, nil] Static string or dynamic Proc that returns instructions
    # @param model [String] The LLM model to use (default: "gpt-4.1-mini")
    # @param tools [Array<Agents::Tool>] Array of tool instances the agent can use
    # @param handoff_agents [Array<Agents::Agent>] Array of agents this agent can hand off to
    # @param mcp_clients [Array<Agents::MCP::Client>, Agents::MCP::Client, nil] MCP clients to attach
    # @param service_name [String, nil] Optional service name for tracing (defaults to agent name)
    def initialize(name:, instructions: nil, model: "gpt-4.1-mini", tools: [], handoff_agents: [], mcp_clients: nil,
                   service_name: nil)
      @name = name
      @instructions = instructions
      @model = model
      @tools = tools.dup
      @handoff_agents = []
      @mcp_clients = []
      @service_name = service_name || name.downcase.gsub(/\s+/, "_")

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
        @tools + handoff_tools
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

    # Add MCP clients to this agent, connecting and loading their tools
    #
    # @param clients [Agents::MCP::Client, Array<Agents::MCP::Client>] Client(s) to add
    # @return [self] Returns self for method chaining
    # @example Adding MCP clients
    #   filesystem_client = Agents::MCP::Client.new(name: "fs", command: "npx", args: ["fs-server"])
    #   agent.add_mcp_clients(filesystem_client)
    #
    #   # Or add multiple clients
    #   agent.add_mcp_clients([filesystem_client, api_client])
    def add_mcp_clients(clients)
      clients_array = Array(clients)

      clients_array.each do |client|
        add_mcp_client(client)
      end

      self
    end

    # Add a single MCP client to this agent
    #
    # @param client [Agents::MCP::Client] The MCP client to add
    # @return [self] Returns self for method chaining
    def add_mcp_client(client)
      @mutex.synchronize do
        # Store the client reference
        @mcp_clients << client unless @mcp_clients.include?(client)

        # Connect and load tools
        begin
          client.connect unless client.connected?
          mcp_tools = client.list_tools

          # Check for tool name collisions and warn
          existing_tool_names = @tools.map { |t| t.class.name }.to_set
          mcp_tools.each do |tool|
            tool_name = tool.class.name
            if existing_tool_names.include?(tool_name)
              warn "Tool name collision: '#{tool_name}' from MCP client '#{client.name}' conflicts with existing tool"
            else
              @tools << tool
              existing_tool_names << tool_name
            end
          end
        rescue StandardError => e
          warn "Failed to load tools from MCP client '#{client.name}': #{e.message}"
          # Continue without this client's tools rather than failing entirely
        end
      end

      self
    end

    # Refresh MCP tools by reconnecting to all clients and reloading their tools
    # This can be used if MCP servers have updated their available tools
    #
    # @return [self] Returns self for method chaining
    def refresh_mcp_tools
      @mutex.synchronize do
        # Remove existing MCP tools
        @tools.reject! { |tool| tool.is_a?(MCP::Tool) }

        # Reload tools from all MCP clients
        @mcp_clients.each do |client|
          client.invalidate_tools_cache
          mcp_tools = client.list_tools(refresh: true)
          @tools.concat(mcp_tools)
        rescue StandardError => e
          warn "Failed to refresh tools from MCP client '#{client.name}': #{e.message}"
        end
      end

      self
    end

    # Get all MCP clients attached to this agent
    #
    # @return [Array<Agents::MCP::Client>] Array of MCP clients
    def mcp_clients
      @mutex.synchronize { @mcp_clients.dup }
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
    # @option changes [String] :service_name New service name for tracing
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
        mcp_clients: changes.fetch(:mcp_clients, changes.key?(:mcp_clients) ? nil : @mcp_clients),
        service_name: changes.fetch(:service_name, @service_name)
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
