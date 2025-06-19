#!/usr/bin/env ruby
# frozen_string_literal: true

# Airline booking example demonstrating shared context between agents
# This replicates the Python airline example with Ruby agents

# Add the lib directory to load path for development
$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))

require "agents"

# Load our airline-specific classes
require_relative "context"
require_relative "tools"
require_relative "agents"

# Configure the gem
Agents.configure do |config|
  config.openai_api_key = ENV["OPENAI_API_KEY"]
  config.default_model = "gpt-4.1"
  config.debug = true
end

# Check if we're properly configured
unless Agents.configuration.configured?
  puts "❌ No API keys configured. Please set OPENAI_API_KEY environment variable."
  puts "   Example: export OPENAI_API_KEY=your_key_here"
  exit 1
end

puts "✅ Airline booking system configured"
puts "Available providers: #{Agents.configuration.available_providers.join(", ")}"

# Create shared context for the conversation
context = AirlineContext.new

# Simulate a customer service conversation
puts "\n🎯 Welcome to Airline Customer Service!"
puts "I'll demonstrate the multi-agent system with shared context.\n"

# Test FAQ functionality
puts "\n--- Testing FAQ Agent ---"
faq_agent = FaqAgent.new(context: context)

puts "\nUser: What are the baggage rules?"
response = faq_agent.call("What are the baggage rules?")
puts "FAQ Agent: #{response.content}"

puts "\nUser: How many seats are on the plane?"
response = faq_agent.call("How many seats are on the plane?")
puts "FAQ Agent: #{response.content}"

# Test seat booking with context
puts "\n--- Testing Seat Booking Agent ---"

# First, set up flight number (simulating handoff hook)
context.assign_flight_number!
puts "Flight number assigned: #{context.flight_number}"

seat_agent = SeatBookingAgent.new(context: context)

puts "\nUser: I want to change my seat"
response = seat_agent.call("I want to change my seat")
puts "Seat Agent: #{response}"

# Simulate the customer providing confirmation and seat choice
puts "\nUser: My confirmation number is ABC123 and I want seat 12A"
response = seat_agent.call("My confirmation number is ABC123 and I want seat 12A")
puts "Seat Agent: #{response}"

# Show context state
puts "\n📊 Context after seat booking:"
puts "Confirmation: #{context.confirmation_number}"
puts "Seat: #{context.seat_number}"
puts "Flight: #{context.flight_number}"
puts "Context data: #{context.to_h}"

# Test triage agent
puts "\n--- Testing Triage Agent ---"
triage_agent = TriageAgent.new(context: context)

puts "\nUser: I have a question about wifi"
response = triage_agent.call("I have a question about wifi")
puts "Triage Agent: #{response}"

puts "\n--- Context History ---"
puts "Agent transitions: #{context.agent_transitions}"

puts "\n✅ Airline booking example completed!"
puts "This demonstrates:"
puts "- Shared context between agents"
puts "- Context-aware tools that modify shared state"
puts "- Different agents handling different responsibilities"
puts "- Context persistence across agent handoffs"
