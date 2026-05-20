# frozen_string_literal: true

require_relative "../../lib/agents"
require_relative "tools"

module CSDemo
  module Airline
    class AgentsFactory
      MODEL = ENV.fetch("CS_DEMO_MODEL", "gpt-5.2")

      def self.create_agents
        new.create_agents
      end

      def create_agents
        triage = triage_agent
        faq = faq_agent
        seats = seat_special_services_agent
        flight = flight_information_agent
        booking = booking_cancellation_agent
        refunds = refunds_compensation_agent

        triage.register_handoffs(flight, booking, seats, faq, refunds)
        faq.register_handoffs(triage)
        seats.register_handoffs(refunds, triage)
        flight.register_handoffs(booking, triage)
        booking.register_handoffs(seats, refunds, triage)
        refunds.register_handoffs(faq, triage)

        {
          triage: triage,
          faq: faq,
          seats: seats,
          flight: flight,
          booking: booking,
          refunds: refunds
        }
      end

      private

      def triage_agent
        Agents::Agent.new(
          name: "Triage Agent",
          model: MODEL,
          temperature: 0.2,
          instructions: <<~PROMPT,
            #{Agents::RECOMMENDED_HANDOFF_PROMPT_PREFIX}
            You are a helpful airline triage agent for Airline Co.
            Route the customer to the best specialist: Flight Information for status and alternates, Booking and Cancellation for booking changes, Seat and Special Services for seating needs, FAQ for policy questions, and Refunds and Compensation for disruption support.
            If the message mentions Paris, New York, or Austin and trip context is missing, call get_trip_details first to populate the disrupted itinerary.
            If the request is clear, hand off immediately and let the specialist complete the work. Never emit more than one handoff in a message.
          PROMPT
          tools: [GetTripDetailsTool.new]
        )
      end

      def flight_information_agent
        Agents::Agent.new(
          name: "Flight Information Agent",
          model: MODEL,
          temperature: 0.3,
          instructions: lambda { |context|
            state = context.context[:state] || {}
            <<~PROMPT
              #{Agents::RECOMMENDED_HANDOFF_PROMPT_PREFIX}
              You are the Flight Information Agent. Provide flight status, connection risk, and quick options to keep trips on track.
              The current confirmation number is #{state[:confirmation_number] || "[unknown]"} and the current flight is #{state[:flight_number] || "[unknown]"}.
              Use flight_status_tool immediately to share current status. If a delay or cancellation impacts the trip, call get_matching_flights to propose alternatives, then hand off to Booking and Cancellation so the customer can be rebooked.
              Work autonomously: chain tool calls when data is present, then emit a single handoff when needed.
            PROMPT
          },
          tools: [FlightStatusTool.new, GetMatchingFlightsTool.new]
        )
      end

      def booking_cancellation_agent
        Agents::Agent.new(
          name: "Booking and Cancellation Agent",
          model: MODEL,
          temperature: 0.3,
          instructions: lambda { |context|
            state = context.context[:state] || {}
            <<~PROMPT
              #{Agents::RECOMMENDED_HANDOFF_PROMPT_PREFIX}
              You are the Booking and Cancellation Agent. You cancel, book, or rebook customers when plans change.
              Work from confirmation #{state[:confirmation_number] || "[unknown]"} and flight #{state[:flight_number] || "[unknown]"}.
              For cancellations, confirm the details when needed and use cancel_flight. For rebooking, call get_matching_flights if options are not already available, then book_new_flight.
              Summarize what changed and share the updated confirmation and seat assignment. After rebooking, hand off to Seat and Special Services if a seat preference exists, otherwise Refunds and Compensation if the trip was disrupted, otherwise Triage.
            PROMPT
          },
          tools: [CancelFlightTool.new, GetMatchingFlightsTool.new, BookNewFlightTool.new]
        )
      end

      def seat_special_services_agent
        Agents::Agent.new(
          name: "Seat and Special Services Agent",
          model: MODEL,
          temperature: 0.3,
          instructions: lambda { |context|
            state = context.context[:state] || {}
            <<~PROMPT
              #{Agents::RECOMMENDED_HANDOFF_PROMPT_PREFIX}
              You are the Seat and Special Services Agent. Handle seat changes and medical or special service requests.
              The customer's confirmation number is #{state[:confirmation_number] || "[unknown]"} for flight #{state[:flight_number] || "[unknown]"} and current seat #{state[:seat_number] || "[unassigned]"}.
              If they want to choose visually, call display_seat_map. If they give a specific standard seat, call update_seat. For front row or medical requests, call assign_special_service_seat.
              Confirm the new seat and remind the customer it is saved on their confirmation. If the request is unrelated to seats or special services, hand off to Triage.
            PROMPT
          },
          tools: [UpdateSeatTool.new, AssignSpecialServiceSeatTool.new, DisplaySeatMapTool.new]
        )
      end

      def faq_agent
        Agents::Agent.new(
          name: "FAQ Agent",
          model: MODEL,
          temperature: 0.2,
          instructions: <<~PROMPT,
            #{Agents::RECOMMENDED_HANDOFF_PROMPT_PREFIX}
            You are the FAQ Agent. Answer common airline policy questions.
            Identify the latest customer question, use faq_lookup_tool, and answer with the retrieved answer. If compensation is needed, offer to transfer to Refunds and Compensation.
          PROMPT
          tools: [FaqLookupTool.new]
        )
      end

      def refunds_compensation_agent
        Agents::Agent.new(
          name: "Refunds and Compensation Agent",
          model: MODEL,
          temperature: 0.3,
          instructions: lambda { |context|
            state = context.context[:state] || {}
            <<~PROMPT
              #{Agents::RECOMMENDED_HANDOFF_PROMPT_PREFIX}
              You are the Refunds and Compensation Agent. You help customers understand and receive compensation after disruptions.
              Work from confirmation #{state[:confirmation_number] || "[unknown]"}. Current case id: #{state[:compensation_case_id] || "[not opened]"}.
              If the customer experienced a delay or missed connection, consult policy with faq_lookup_tool, summarize the issue, and use issue_compensation to open a case and issue hotel and meal support.
              Confirm what was issued and what receipts to keep. Return to Triage when finished.
            PROMPT
          },
          tools: [IssueCompensationTool.new, FaqLookupTool.new]
        )
      end
    end
  end
end
