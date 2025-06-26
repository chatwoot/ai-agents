# frozen_string_literal: true

module ISPSupport
  # Tool for creating sales leads in the CRM system.
  class CreateLeadTool < Agents::Tool
    description "Create a new sales lead with customer information"
    param :name, String, "Customer's full name"
    param :email, String, "Customer's email address"
    param :desired_plan, String, "Plan the customer is interested in"

    def perform(_tool_context, name:, email:, desired_plan:)
      "Lead created for #{name} (#{email}) interested in #{desired_plan} plan. Sales team will contact within 24 hours."
    end
  end
end
