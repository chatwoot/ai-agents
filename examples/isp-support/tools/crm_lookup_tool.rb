# frozen_string_literal: true

require "json"

module ISPSupport
  # Tool for looking up customer information from the CRM system.
  class CrmLookupTool < Agents::Tool
    description "Look up customer account information by account ID"
    param :account_id, type: "string", desc: "Customer account ID (e.g., CUST001)"

    def perform(tool_context, account_id:)
      data_file = File.join(__dir__, "../data/customers.json")
      return "Customer database unavailable" unless File.exist?(data_file)

      begin
        customers = JSON.parse(File.read(data_file))
        customer = customers[account_id.upcase]

        return "Customer not found" unless customer

        # Store customer information in shared state for other tools/agents
        tool_context.state[:customer_id] = account_id.upcase
        tool_context.state[:customer_name] = customer["name"]
        tool_context.state[:current_plan] = customer["current_plan"]
        tool_context.state[:account_status] = customer["status"]
        tool_context.state[:monthly_usage] = customer["monthly_usage_gb"]

        # Return clean message for the agent
        "Found customer #{customer['name']} (#{account_id.upcase}). " \
        "Current plan: #{customer['current_plan']}, Status: #{customer['status']}"
      rescue StandardError
        "Error looking up customer"
      end
    end
  end
end
