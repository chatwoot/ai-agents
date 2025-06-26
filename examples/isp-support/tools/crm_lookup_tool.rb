# frozen_string_literal: true

require "json"

module ISPSupport
  # Tool for looking up customer information from the CRM system.
  class CrmLookupTool < Agents::Tool
    description "Look up customer account information by account ID"
    param :account_id, String, "Customer account ID (e.g., CUST001)"

    def perform(_tool_context, account_id:)
      data_file = File.join(__dir__, "../data/customers.json")
      return "Customer database unavailable" unless File.exist?(data_file)

      begin
        customers = JSON.parse(File.read(data_file))
        customer = customers[account_id.upcase]

        return "Customer not found" unless customer

        # Return the entire customer data as JSON for the agent to process
        customer.to_json
      rescue StandardError
        "Error looking up customer"
      end
    end
  end
end
