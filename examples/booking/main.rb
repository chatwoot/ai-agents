#!/usr/bin/env ruby
# frozen_string_literal: true

# Interactive airline booking system using the new Runner API
# This demonstrates the seamless handoff experience where users never need to repeat questions

# Add the lib directory to load path for development
$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))

require "agents"
require "securerandom"

# Load our airline-specific classes
require_relative "context"
require_relative "tools"
require_relative "agents"

# Configure the gem
Agents.configure do |config|
  config.openai_api_key = ENV["OPENAI_API_KEY"]
  config.default_model = "gpt-4o"
  config.debug = false
end

# Check if we're properly configured
unless Agents.configuration.configured?
  puts "❌ No API keys configured. Please set OPENAI_API_KEY environment variable."
  puts "   Example: export OPENAI_API_KEY=your_key_here"
  exit 1
end

# Create shared context for the conversation
context = AirlineContext.new

# Create Runner with TriageAgent as starting point
runner = Agents::Runner.new(
  initial_agent: TriageAgent,
  context: context
)

puts "=" * 60
puts "🎯 Welcome to Interactive Airline Customer Service!"
puts "=" * 60
puts
puts "You're chatting with our AI customer service system using the new Runner API."
puts "The system has multiple specialized agents:"
puts "• Triage Agent - Routes your requests to the right specialist"
puts "• FAQ Agent - Answers questions about baggage, seats, wifi, etc."
puts "• Seat Booking Agent - Handles seat changes and updates"
puts
puts "Type 'exit' to quit, 'context' to see shared context"
puts "=" * 60
puts

loop do
  # Show current agent
  current_agent_name = runner.current_agent&.class&.name&.split("::")&.last || "TriageAgent"
  print "\n[#{current_agent_name}] You: "

  user_input = gets&.chomp&.strip
  break unless user_input # Exit if EOF (Ctrl+D)

  # Handle special commands
  case user_input.downcase
  when "exit", "quit", "bye"
    puts "\n👋 Thanks for using our airline service! Have a great flight!"
    break

  when "context"
    puts "\n📊 Current Context:"
    puts "Flight: #{context.flight_number || "None assigned"}"
    puts "Passenger: #{context.passenger_name || "Not set"}"
    puts "Confirmation: #{context.confirmation_number || "Not set"}"
    puts "Seat: #{context.seat_number || "Not set"}"
    puts "All data: #{context.to_h}"
    puts "Agent transitions: #{context.agent_transitions.size} recorded"
    next

  when ""
    next
  end

  # Process through Runner
  begin
    puts "\n[Agent] 🤔 Processing..."
    $stdout.flush

    # This is the magic - one call handles everything including handoffs
    final_response = runner.process(user_input)

    print "\r#{" " * 20}\r" # Clear "Processing..."
    puts "[Agent] #{final_response}"

    # Show current agent after processing
    current_agent_name = runner.current_agent&.class&.name&.split("::")&.last
    puts "\n💡 Current agent: #{current_agent_name}" if current_agent_name
  rescue StandardError => e
    print "\r#{" " * 20}\r" # Clear "Processing..."
    puts "❌ Sorry, I encountered an error: #{e.message}"
    puts "Please try again or type 'exit' to quit."
  end
end

puts "\n📋 Final Context Summary:"
puts "Flight: #{context.flight_number || "None"}"
puts "Passenger: #{context.passenger_name || "None"}"
puts "Confirmation: #{context.confirmation_number || "None"}"
puts "Seat: #{context.seat_number || "None"}"

if context.agent_transitions.any?
  puts "\n🔄 Agent Transitions:"
  context.agent_transitions.each_with_index do |transition, i|
    puts "  #{i + 1}. #{transition[:from]} → #{transition[:to]} (#{transition[:reason] || "No reason"})"
  end
end

puts "\n🎉 Conversation Summary:"
puts runner.conversation_summary
