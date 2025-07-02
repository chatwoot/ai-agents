# frozen_string_literal: true

require_relative "research_agent"
require_relative "analysis_agent"
require_relative "integrations_agent"
require_relative "answer_suggestion_agent"

module Copilot
  class CopilotOrchestrator
    def self.create
      # Create specialized agents
      research_agent = ResearchAgent.create
      analysis_agent = AnalysisAgent.create
      integrations_agent = IntegrationsAgent.create
      answer_suggestion_agent = AnswerSuggestionAgent.create

      # Create main orchestrator with sub-agents as tools
      Agents::Agent.new(
        name: "Support Copilot",
        instructions: orchestrator_instructions,
        model: "gpt-4o-mini",
        tools: [
          research_agent.as_tool(
            name: "research_customer_history",
            description: "Research customer history, similar cases, and behavioral patterns"
          ),
          analysis_agent.as_tool(
            name: "analyze_conversation",
            description: "Analyze conversation tone, sentiment, and communication quality"
          ),
          integrations_agent.as_tool(
            name: "check_technical_systems",
            description: "Check Linear issues, billing info, and create engineering tickets"
          ),
          answer_suggestion_agent.as_tool(
            name: "get_knowledge_base_help",
            description: "Search knowledge base and get specific article content"
          )
        ]
      )
    end

    def self.orchestrator_instructions
      <<~INSTRUCTIONS
        You are the Support Copilot, helping support agents provide excellent customer service.

        **Your specialist agents:**
        - `research_customer_history`: Deep investigation of customer history and similar cases
        - `analyze_conversation`: Conversation analysis and communication guidance
        - `check_technical_systems`: Technical context from Linear and billing from Stripe
        - `get_knowledge_base_help`: Knowledge base search and documentation retrieval

        **Your role is to:**
        - Help support agents understand customer situations
        - Provide context and recommendations for responses
        - Draft replies and suggest solutions
        - Coordinate insights from multiple specialist agents when needed

        **Usage patterns:**
        - "What should I tell this customer?" → Use multiple agents to understand context and suggest response
        - "How should I handle this situation?" → Analyze conversation and research similar cases
        - "Is this a known technical issue?" → Check technical systems for bugs or known issues
        - "What's this customer's history?" → Research customer background and patterns

        Don't respond with irrelevant information or personal opinions. Keep it simple and to the point.

        Provide clear, actionable guidance.Be concise but thorough. Focus on helping the support agent succeed.
      INSTRUCTIONS
    end
  end
end
