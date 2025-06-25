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
      # Step 1: Create agents without handoffs
      triage = create_triage_agent
      customer_info = create_customer_info_agent
      sales = create_sales_agent
      support = create_support_agent

      # Step 2: Wire up handoff relationships
      {
        triage: triage.clone(handoff_agents: [customer_info, sales, support]),
        customer_info: customer_info.clone(handoff_agents: [triage, sales, support]),
        sales: sales.clone(handoff_agents: [triage, customer_info]),
        support: support.clone(handoff_agents: [triage, customer_info])
      }
    end

    private

    def create_triage_agent
      Agents::Agent.new(
        name: "Triage Agent",
        instructions: triage_instructions,
        model: "gpt-4o",
        tools: []
      )
    end

    def create_customer_info_agent
      Agents::Agent.new(
        name: "Customer Info Agent",
        instructions: customer_info_instructions,
        model: "gpt-4o",
        tools: [ISPSupport::CrmLookupTool.new]
      )
    end

    def create_sales_agent
      Agents::Agent.new(
        name: "Sales Agent",
        instructions: sales_instructions,
        model: "gpt-4o",
        tools: [ISPSupport::CreateLeadTool.new, ISPSupport::CreateCheckoutTool.new]
      )
    end

    def create_support_agent
      Agents::Agent.new(
        name: "Support Agent",
        instructions: support_instructions,
        model: "gpt-4o",
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
        You are the Customer Info Agent for an ISP. You handle account information, billing inquiries,#{" "}
        and service plan details using the CRM system.

        **Your tools:**
        - `crm_lookup`: Look up customer account details by account ID
        - Handoff tools: Route to other agents when needed

        **When to hand off:**
        - Sales questions (upgrades, new plans) → Sales Agent
        - Technical issues → Support Agent#{"  "}
        - Complex requests outside your scope → Triage Agent

        **Instructions:**
        - Always ask for account ID before looking up information
        - Present information clearly and professionally
        - Protect sensitive data - only share what's appropriate
        - If customer wants to make changes or upgrades, hand off to Sales Agent
      INSTRUCTIONS
    end

    def sales_instructions
      <<~INSTRUCTIONS
        You are the Sales Agent for an ISP. You handle new customer acquisition, service upgrades,#{" "}
        and plan changes.

        **Your tools:**
        - `create_lead`: Create sales leads with customer information
        - `create_checkout`: Generate secure checkout links for purchases
        - Handoff tools: Route to other agents when needed

        **When to hand off:**
        - Need account details for existing customers → Customer Info Agent
        - Technical questions → Support Agent
        - Non-sales requests → Triage Agent

        **Instructions:**
        - Be enthusiastic but not pushy
        - Gather required info: name, email, desired plan for leads
        - For existing customers wanting upgrades, get account details first
        - Create checkout links for confirmed purchases
        - Always explain next steps after creating leads or checkout links
      INSTRUCTIONS
    end

    def support_instructions
      <<~INSTRUCTIONS
        You are the Support Agent for an ISP. You provide technical support and troubleshooting#{" "}
        for customer issues.

        **Your tools:**
        - `search_docs`: Find troubleshooting steps in knowledge base
        - `escalate_to_human`: Transfer complex issues to human agents
        - Handoff tools: Route to other agents when needed

        **When to hand off:**
        - Need account verification → Customer Info Agent
        - Customer wants to change plans → Sales Agent
        - Non-technical requests → Triage Agent

        **Instructions:**
        - Start with basic troubleshooting from docs search
        - Be patient and provide step-by-step guidance
        - If customer gets frustrated or issue persists, escalate to human
        - For account-related technical issues, may need Customer Info Agent first
      INSTRUCTIONS
    end
  end
end
