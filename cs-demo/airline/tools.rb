# frozen_string_literal: true

require "securerandom"
require_relative "../../lib/agents"
require_relative "data"

module CSDemo
  module Airline
    module ToolHelpers
      private

      def state_for(tool_context)
        tool_context.context[:state] ||= Airline.initial_state
      end

      def random_confirmation
        SecureRandom.alphanumeric(6).upcase
      end
    end

    class FaqLookupTool < Agents::Tool
      description "Lookup frequently asked questions."
      param :question, type: "string", desc: "Customer question"

      def name
        "faq_lookup_tool"
      end

      def perform(_tool_context, question:)
        q = question.to_s.downcase
        return baggage_answer if q.include?("bag") || q.include?("baggage")
        return compensation_answer if q.match?(/compensation|delay|voucher/)
        return seats_answer if q.include?("seat") || q.include?("plane")
        return "We have free wifi on the plane. Join Airline-Wifi." if q.include?("wifi")

        "I'm sorry, I don't know the answer to that question."
      end

      private

      def baggage_answer
        "You are allowed to bring one bag on the plane. It must be under 50 pounds and 22 inches x 14 inches x 9 inches. If a bag is delayed or missing, file a baggage claim and we will track it for delivery."
      end

      def compensation_answer
        "For lengthy delays we provide duty-of-care: hotel and meal vouchers plus ground transport where needed. If the delay is over 3 hours or causes a missed connection, we also open a compensation case and can offer miles or travel credit. A Refunds & Compensation agent can submit the case and share voucher details."
      end

      def seats_answer
        "There are 120 seats on the plane. There are 22 business class seats and 98 economy seats. Exit rows are rows 4 and 16. Rows 5-8 are Economy Plus, with extra legroom."
      end
    end

    class GetTripDetailsTool < Agents::Tool
      include ToolHelpers

      description "Infer the trip from customer text and hydrate context."
      param :message, type: "string", desc: "The customer's latest message"

      def name
        "get_trip_details"
      end

      def perform(tool_context, message:)
        state = state_for(tool_context)
        scenario = message.to_s.downcase.match?(/paris|new york|austin/) ? :disrupted : :on_time
        Airline.apply_itinerary_defaults(state, scenario_key: scenario)
        segments = state[:itinerary] || []
        summary = segments.map do |segment|
          "#{segment[:flight_number]} #{segment[:origin]} -> #{segment[:destination]} status: #{segment[:status]}"
        end.join("; ")

        "Hydrated #{scenario} itinerary: flight #{state[:flight_number]}, confirmation #{state[:confirmation_number]}, origin #{state[:origin]}, destination #{state[:destination]}. #{summary}"
      end
    end

    class UpdateSeatTool < Agents::Tool
      include ToolHelpers

      description "Update the customer's seat for a confirmation number."
      param :confirmation_number, type: "string", desc: "Customer confirmation number"
      param :new_seat, type: "string", desc: "Requested seat"

      def name
        "update_seat"
      end

      def perform(tool_context, confirmation_number:, new_seat:)
        state = state_for(tool_context)
        Airline.apply_itinerary_defaults(state)
        state[:confirmation_number] = confirmation_number
        state[:seat_number] = new_seat
        state[:show_seat_map] = false

        "Updated seat to #{new_seat} for confirmation number #{confirmation_number}"
      end
    end

    class FlightStatusTool < Agents::Tool
      include ToolHelpers

      description "Lookup status for a flight."
      param :flight_number, type: "string", desc: "Flight number"

      def name
        "flight_status_tool"
      end

      def perform(tool_context, flight_number:)
        state = state_for(tool_context)
        state[:flight_number] = flight_number
        match = Airline.get_itinerary_for_flight(flight_number)
        return default_status(flight_number) unless match

        scenario, itinerary = match
        Airline.apply_itinerary_defaults(state, scenario_key: scenario)
        segment = itinerary[:segments].find { |item| item[:flight_number].casecmp?(flight_number) }
        replacement = itinerary[:rebook_options].find { |item| item[:flight_number].casecmp?(flight_number) }
        return segment_status(segment, scenario) if segment
        return replacement_status(replacement) if replacement

        default_status(flight_number)
      end

      private

      def segment_status(segment, scenario)
        details = [
          "Flight #{segment[:flight_number]} (#{segment[:origin]} to #{segment[:destination]})",
          "Status: #{segment[:status]}"
        ]
        details << "Gate: #{segment[:gate]}" if segment[:gate]
        details << "Scheduled #{segment[:departure]} -> #{segment[:arrival]}" if segment[:departure] && segment[:arrival]
        if scenario == :disrupted && segment[:flight_number] == "PA441"
          details << "This delay will cause a missed connection to NY802. Reaccommodation is recommended."
        end
        details.join(" | ")
      end

      def replacement_status(replacement)
        "Replacement flight #{replacement[:flight_number]} (#{replacement[:origin]} to #{replacement[:destination]}) is available. Departure #{replacement[:departure]} arriving #{replacement[:arrival]}. Seat #{replacement[:seat]} held."
      end

      def default_status(flight_number)
        "Flight #{flight_number} is on time and scheduled to depart at gate A10."
      end
    end

    class GetMatchingFlightsTool < Agents::Tool
      include ToolHelpers

      description "Find replacement flights when a segment is delayed or cancelled."
      param :origin, type: "string", desc: "Optional origin filter", required: false
      param :destination, type: "string", desc: "Optional destination filter", required: false

      def name
        "get_matching_flights"
      end

      def perform(tool_context, origin: nil, destination: nil)
        state = state_for(tool_context)
        scenario, itinerary = Airline.active_itinerary(state)
        Airline.apply_itinerary_defaults(state, scenario_key: scenario)
        options = matching_options(itinerary[:rebook_options], origin, destination)
        return "All flights are operating on time. No alternate flights are needed." if options.empty?

        lines = options.map do |option|
          "#{option[:flight_number]} #{option[:origin]} -> #{option[:destination]} dep #{option[:departure]} arr #{option[:arrival]} | seat #{option[:seat] || "auto-assign"} | #{option[:note]}"
        end
        lines << "These options arrive in Austin the next day. Overnight hotel and meals are covered." if scenario == :disrupted
        "Matching flights:\n#{lines.join("\n")}"
      end

      private

      def matching_options(options, origin, destination)
        filtered = options.select do |option|
          (origin.nil? || option[:origin].downcase.include?(origin.downcase)) &&
            (destination.nil? || option[:destination].downcase.include?(destination.downcase))
        end
        filtered.empty? ? options : filtered
      end
    end

    class BookNewFlightTool < Agents::Tool
      include ToolHelpers

      description "Book a new or replacement flight and auto-assign a seat."
      param :flight_number, type: "string", desc: "Preferred replacement flight number", required: false

      def name
        "book_new_flight"
      end

      def perform(tool_context, flight_number: nil)
        state = state_for(tool_context)
        scenario, itinerary = Airline.active_itinerary(state)
        Airline.apply_itinerary_defaults(state, scenario_key: scenario)
        selection = select_option(itinerary[:rebook_options], flight_number)
        return placeholder_booking(state, flight_number) unless selection

        state[:flight_number] = selection[:flight_number]
        state[:seat_number] = selection[:seat] || state[:seat_number] || "auto-assign"
        state[:confirmation_number] ||= random_confirmation
        state[:itinerary] = updated_itinerary(state[:itinerary], selection, scenario)

        "Rebooked to #{selection[:flight_number]} from #{selection[:origin]} to #{selection[:destination]}. Departure #{selection[:departure]}, arrival #{selection[:arrival]} (next day arrival in Austin). Seat assigned: #{state[:seat_number]}. Confirmation #{state[:confirmation_number]}."
      end

      private

      def select_option(options, flight_number)
        return options.first if flight_number.nil? || flight_number.empty?

        options.find { |option| option[:flight_number].casecmp?(flight_number) } || options.first
      end

      def placeholder_booking(state, flight_number)
        state[:confirmation_number] ||= random_confirmation
        seat = state[:seat_number] || "auto-assign"
        "Booked flight #{flight_number || "TBD"} with confirmation #{state[:confirmation_number]}. Seat assignment: #{seat}."
      end

      def updated_itinerary(current_itinerary, selection, scenario)
        segments = (current_itinerary || []).reject do |segment|
          scenario == :disrupted &&
            segment[:origin].to_s.start_with?("New York") &&
            segment[:destination].to_s.start_with?("Austin")
        end
        segments + [{
          flight_number: selection[:flight_number],
          origin: selection[:origin],
          destination: selection[:destination],
          departure: selection[:departure],
          arrival: selection[:arrival],
          status: "Confirmed replacement flight",
          gate: "TBD"
        }]
      end
    end

    class AssignSpecialServiceSeatTool < Agents::Tool
      include ToolHelpers

      description "Assign front row or special service seating for medical needs."
      param :seat_request, type: "string", desc: "Seat or accommodation request", required: false

      def name
        "assign_special_service_seat"
      end

      def perform(tool_context, seat_request: "front row for medical needs")
        state = state_for(tool_context)
        Airline.apply_itinerary_defaults(state)
        preferred_seat = seat_request.to_s.downcase.include?("front") ? "1A" : "2A"
        state[:seat_number] = preferred_seat
        state[:special_service_note] = seat_request
        state[:confirmation_number] ||= random_confirmation
        state[:show_seat_map] = false

        "Secured #{seat_request} seat #{preferred_seat} on flight #{state[:flight_number] || "upcoming segment"}. Confirmation #{state[:confirmation_number]} noted with special service flag."
      end
    end

    class IssueCompensationTool < Agents::Tool
      include ToolHelpers

      description "Create a compensation case and issue hotel/meal vouchers."
      param :reason, type: "string", desc: "Reason for compensation", required: false

      def name
        "issue_compensation"
      end

      def perform(tool_context, reason: "Delay causing missed connection")
        state = state_for(tool_context)
        scenario, itinerary = Airline.active_itinerary(state)
        Airline.apply_itinerary_defaults(state, scenario_key: scenario)
        state[:compensation_case_id] ||= "CMP-#{rand(1000..9999)}"
        state[:vouchers] = itinerary[:vouchers].values unless itinerary[:vouchers].empty?
        vouchers_text = state[:vouchers]&.join("; ") || "Documented compensation with no vouchers required."

        "Opened compensation case #{state[:compensation_case_id]} for: #{reason}. Issued: #{vouchers_text}. Keep receipts for any hotel or meal costs and attach them to this case."
      end
    end

    class DisplaySeatMapTool < Agents::Tool
      include ToolHelpers

      description "Display an interactive seat map to the customer so they can choose a new seat."

      def name
        "display_seat_map"
      end

      def perform(tool_context)
        state_for(tool_context)[:show_seat_map] = true
        "DISPLAY_SEAT_MAP"
      end
    end

    class CancelFlightTool < Agents::Tool
      include ToolHelpers

      description "Cancel a flight."

      def name
        "cancel_flight"
      end

      def perform(tool_context)
        state = state_for(tool_context)
        Airline.apply_itinerary_defaults(state)
        state[:confirmation_number] ||= random_confirmation
        "Flight #{state[:flight_number]} successfully cancelled for confirmation #{state[:confirmation_number]}"
      end
    end
  end
end
