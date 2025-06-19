# frozen_string_literal: true

# FAQ Agent - handles general airline questions
class FaqAgent < Agents::Agent
  name "FAQ Agent"
  instructions Agents.prompt_with_handoff_instructions(<<~INSTRUCTIONS)
    You are an FAQ agent for airline customer service.

    # Routine
    1. Identify the last question asked by the customer from the conversation.
    2. Use the faq lookup tool to answer the question. Do not rely on your own knowledge.
    3. If you cannot answer the question, use transfer_to_triage_agent.
  INSTRUCTIONS

  uses FaqLookupTool
end

# Seat Booking Agent - handles seat changes
class SeatBookingAgent < Agents::Agent
  name "Seat Booking Agent"
  instructions Agents.prompt_with_handoff_instructions(<<~INSTRUCTIONS)
    You are a seat booking agent for airline customer service.

    # Routine
    1. Check the conversation history for any existing confirmation number or seat change request.
    2. If not provided, ask for their confirmation number.
    3. If not provided, ask the customer what their desired seat number is.
    4. Use the update seat tool to update the seat on the flight.

    If the customer asks a question that is not related to seat booking, use transfer_to_triage_agent.
  INSTRUCTIONS

  uses UpdateSeatTool
end

# Triage Agent - routes customers to appropriate agents
class TriageAgent < Agents::Agent
  name "Triage Agent"
  instructions Agents.prompt_with_handoff_instructions(<<~INSTRUCTIONS)
    You are a triaging agent that MUST transfer customers to the right specialist. You cannot handle requests yourself.

    IMPORTANT: You must ALWAYS call one of the transfer functions below:

    - For baggage, seats, wifi, or general airline questions: CALL transfer_to_faq_agent
    - For seat changes, updates, or seat selection: CALL transfer_to_seat_booking_agent

    NEVER try to answer questions yourself. ALWAYS transfer to the appropriate specialist using the transfer functions.

    CRITICAL: Do NOT tell the user about the transfer. Just call the transfer function immediately.
  INSTRUCTIONS

  handoffs FaqAgent, SeatBookingAgent
end

# Configure remaining handoffs after all classes are defined
FaqAgent.handoffs TriageAgent
SeatBookingAgent.handoffs TriageAgent
