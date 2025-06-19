# frozen_string_literal: true

# FAQ lookup tool for airline information
class FaqLookupTool < Agents::Tool
  description "Lookup frequently asked questions about the airline"
  param :question, String, "The question to look up"

  def perform(question:, context: nil)
    question_lower = question.downcase

    if question_lower.include?("bag") || question_lower.include?("baggage")
      "You are allowed to bring one bag on the plane. " \
      "It must be under 50 pounds and 22 inches x 14 inches x 9 inches."
    elsif question_lower.include?("seats") || question_lower.include?("plane")
      "There are 120 seats on the plane. " \
      "There are 22 business class seats and 98 economy seats. " \
      "Exit rows are rows 4 and 16. " \
      "Rows 5-8 are Economy Plus, with extra legroom."
    elsif question_lower.include?("wifi")
      "We have free wifi on the plane, join Airline-Wifi"
    else
      "I'm sorry, I don't know the answer to that question."
    end
  end
end

# Seat update tool that modifies shared context
class UpdateSeatTool < Agents::Tool
  description "Update the seat for a given confirmation number"
  param :confirmation_number, String, "The confirmation number for the flight"
  param :new_seat, String, "The new seat to update to"

  def perform(confirmation_number:, new_seat:, context:)
    # Update the context with booking information
    context.confirmation_number = confirmation_number
    context.seat_number = new_seat

    # Ensure flight number is set (should be set by handoff hook)
    raise "Flight number is required" unless context.flight_number

    # Store in context data hash as well for compatibility
    context[:confirmation_number] = confirmation_number
    context[:seat_number] = new_seat

    "Updated seat to #{new_seat} for confirmation number #{confirmation_number}"
  end
end
