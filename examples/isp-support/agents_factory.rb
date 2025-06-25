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
      customer_info = create_customer_info_agent
      sales = create_sales_agent
      support = create_support_agent

      # Step 2: Wire up handoff relationships using register_handoffs
      # This is much cleaner than complex cloning!

      # Triage can handoff to all specialists
      triage.register_handoffs(customer_info, sales, support)

      # Specialists only handoff back to triage (hub-and-spoke pattern)
      customer_info.register_handoffs(triage)
      sales.register_handoffs(triage)
      support.register_handoffs(triage)

      # Return the configured agents
      {
        triage: triage,
        customer_info: customer_info,
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

    def create_customer_info_agent
      Agents::Agent.new(
        name: "Customer Info Agent",
        instructions: customer_info_instructions,
        model: "gpt-4.1-mini",
        tools: [ISPSupport::CrmLookupTool.new]
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
        tools: [ISPSupport::SearchDocsTool.new, ISPSupport::EscalateToHumanTool.new]
      )
    end

    def triage_instructions
      <<~INSTRUCTIONS
        You are the Triage Agent for an ISP customer support system. Your role is to greet customers#{" "}
        and route them to the appropriate specialist agent based on their needs.

        **Available specialist agents:**
        - **Customer Info Agent**: Account info, billing, plan details, service history
        - **Sales Agent**: New service, upgrades, plan changes, purchasing#{"  "}
        - **Support Agent**: Technical issues, troubleshooting, outages, equipment problems

        **Routing guidelines:**
        - Account/billing questions → Customer Info Agent
        - Want to buy/upgrade/change plans → Sales Agent
        - Technical problems/outages → Support Agent
        - If unclear, ask one clarifying question before routing

        Keep responses brief and professional. Use handoff tools to transfer to specialists.
      INSTRUCTIONS
    end

    def customer_info_instructions
      <<~INSTRUCTIONS
        You are the Customer Info Agent for an ISP. You handle account information, billing inquiries,
        and service plan details using the CRM system.

        **Your tools:**
        - `crm_lookup`: Look up customer account details by account ID
        - Handoff tools: Route back to triage when needed

        **When to hand off:**
        - Sales questions (upgrades, new plans) → Triage Agent for re-routing
        - Technical issues → Triage Agent for re-routing
        - Complex requests outside your scope → Triage Agent

        **Instructions:**
        - Always ask for account ID before looking up information
        - Present information clearly and professionally
        - Protect sensitive data - only share what's appropriate
        - If customer needs different services, hand off to Triage Agent for re-routing
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
        You are the Support Agent for an ISP. You provide technical support and troubleshooting
        for customer issues.

        **Your tools:**
        - `search_docs`: Find troubleshooting steps in knowledge base
        - `escalate_to_human`: Transfer complex issues to human agents
        - Handoff tools: Route back to triage when needed

        **When to hand off:**
        - Need account verification or billing → Triage Agent for re-routing
        - Customer wants to change plans → Triage Agent for re-routing
        - Non-technical requests → Triage Agent

        **Instructions:**
        - Start with basic troubleshooting from docs search
        - Be patient and provide step-by-step guidance
        - If customer gets frustrated or issue persists, escalate to human
        - For account-related issues, suggest customer contact support through triage
      INSTRUCTIONS
    end
  end
end
