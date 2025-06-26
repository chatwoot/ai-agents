# frozen_string_literal: true

require_relative "../../lib/agents"
require_relative "tools/crm_lookup_tool"
require_relative "tools/create_lead_tool"
require_relative "tools/create_checkout_tool"
require_relative "tools/search_docs_tool"
require_relative "tools/escalate_to_human_tool"

module ISPSupport
  # Factory for creating all ISP support agents with proper handoff relationships.
  # This solves the circular dependency problem where agents need to reference each other.
  class AgentsFactory
    def self.create_agents
      new.create_agents
    end

    def create_agents
      # Step 1: Create all agents
      triage = create_triage_agent
      sales = create_sales_agent
      support = create_support_agent

      # Step 2: Wire up handoff relationships using register_handoffs
      # Triage can handoff to specialists
      triage.register_handoffs(sales, support)

      # Specialists can hand back to triage if needed
      sales.register_handoffs(triage)
      support.register_handoffs(triage)

      # Return the configured agents
      {
        triage: triage,
        sales: sales,
        support: support
      }
    end

    private

    def create_triage_agent
      Agents::Agent.new(
        name: "Triage Agent",
        instructions: triage_instructions,
        model: "gpt-4.1-mini",
        tools: []
      )
    end


    def create_sales_agent
      Agents::Agent.new(
        name: "Sales Agent",
        instructions: sales_instructions,
        model: "gpt-4.1-mini",
        tools: [ISPSupport::CreateLeadTool.new, ISPSupport::CreateCheckoutTool.new]
      )
    end

    def create_support_agent
      Agents::Agent.new(
        name: "Support Agent",
        instructions: support_instructions,
        model: "gpt-4.1-mini",
        tools: [
          ISPSupport::CrmLookupTool.new,
          ISPSupport::SearchDocsTool.new, 
          ISPSupport::EscalateToHumanTool.new
        ]
      )
    end

    def triage_instructions
      <<~INSTRUCTIONS
        You are the Triage Agent for an ISP customer support system. Your role is to greet customers#{" "}
        and route them to the appropriate specialist agent based on their needs.

        **Available specialist agents:**
        - **Sales Agent**: New service, upgrades, plan changes, purchasing, billing questions
        - **Support Agent**: Technical issues, troubleshooting, outages, account lookups, service problems

        **Routing guidelines:**
        - Want to buy/upgrade/change plans or billing questions → Sales Agent
        - Technical problems, outages, account info, or service issues → Support Agent
        - If unclear, ask one clarifying question before routing

        Keep responses brief and professional. Use handoff tools to transfer to specialists.
      INSTRUCTIONS
    end


    def sales_instructions
      <<~INSTRUCTIONS
        You are the Sales Agent for an ISP. You handle new customer acquisition, service upgrades,
        and plan changes.

        **Your tools:**
        - `create_lead`: Create sales leads with customer information
        - `create_checkout`: Generate secure checkout links for purchases
        - Handoff tools: Route back to triage when needed

        **When to hand off:**
        - Need account verification or billing info → Triage Agent for re-routing
        - Technical questions → Triage Agent for re-routing
        - Non-sales requests → Triage Agent

        **Instructions:**
        - Be enthusiastic but not pushy
        - Gather required info: name, email, desired plan for leads
        - For existing customers wanting upgrades, ask them to verify account first
        - Create checkout links for confirmed purchases
        - Always explain next steps after creating leads or checkout links
      INSTRUCTIONS
    end

    def support_instructions
      <<~INSTRUCTIONS
        You are the Support Agent for an ISP. You handle technical support, troubleshooting,
        and account information for customers.

        **Your tools:**
        - `crm_lookup`: Look up customer account details by account ID
        - `search_docs`: Find troubleshooting steps in knowledge base
        - `escalate_to_human`: Transfer complex issues to human agents
        - Handoff tools: Route back to triage when needed

        **When to hand off:**
        - Customer wants to buy/upgrade plans → Triage Agent to route to Sales
        - Non-support requests (new purchases) → Triage Agent

        **Instructions:**
        - For account questions: Always ask for account ID and use crm_lookup
        - For technical issues: Start with basic troubleshooting from docs search
        - You can handle both account lookups AND technical support in the same conversation
        - Be patient and provide step-by-step guidance
        - If customer gets frustrated or issue persists, escalate to human
        - Present account information clearly and protect sensitive data
      INSTRUCTIONS
    end
  end
end
