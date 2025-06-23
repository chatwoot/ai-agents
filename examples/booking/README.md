# Airline Booking Example

This example demonstrates a multi-agent airline customer service system with shared context, similar to the Python OpenAI Agents SDK airline example.

## Overview

The system consists of three specialized agents:

- **Triage Agent** - Routes customer requests to the appropriate specialist
- **FAQ Agent** - Answers questions about baggage, seats, wifi, and general airline information
- **Seat Booking Agent** - Handles seat changes and updates

All agents share a common `AirlineContext` that maintains passenger information across agent handoffs.

## Files

- `context.rb` - AirlineContext class for shared state management
- `tools.rb` - Context-aware tools (FAQ lookup, seat updates)
- `agents.rb` - Agent definitions with instructions and tool assignments
- `main.rb` - Interactive chat interface to talk with the agents

## Running the Examples

### Prerequisites

Set your OpenAI API key:
```bash
export OPENAI_API_KEY=your_key_here
```

### Interactive Chat

Chat directly with the agents:

```bash
ruby examples/booking/main.rb
```

Commands:
- Type your questions naturally
- `context` - View current shared context
- `switch triage/faq/seat` - Switch between agents
- `exit` - Quit the chat

Example conversation:
```
[TriageAgent] You: What are the baggage rules?
[TriageAgent] Agent: I'll transfer you to our FAQ agent...

[FaqAgent] You: What's the wifi situation?
[FaqAgent] Agent: We have free wifi on the plane, join Airline-Wifi

[TriageAgent] You: I want to change my seat
[SeatBookingAgent] You: My confirmation is ABC123 and I want seat 12A
[SeatBookingAgent] Agent: Updated seat to 12A for confirmation ABC123
📝 Updated: Confirmation: ABC123, Seat: 12A
```

## Key Features Demonstrated

1. **Shared Context** - All agents share the same AirlineContext instance
2. **Context-Aware Tools** - Tools automatically receive and can modify shared state
3. **Agent Specialization** - Each agent handles specific types of requests
4. **State Persistence** - Context persists across agent handoffs
5. **Ruby Idioms** - Clean Ruby syntax with keyword arguments and blocks

## Context Management

The `AirlineContext` tracks:
- `passenger_name` - Customer name
- `confirmation_number` - Booking confirmation
- `seat_number` - Current seat assignment
- `flight_number` - Flight identifier
- Agent transition history and metadata

Tools can read from and write to this shared context, enabling seamless handoffs between specialized agents.
