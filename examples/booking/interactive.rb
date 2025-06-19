#!/usr/bin/env ruby
# frozen_string_literal: true

# Interactive airline booking system - chat with the agents!
# This lets you have real conversations with the multi-agent system

# Enable RubyLLM debug mode to see tool call details
ENV["RUBYLLM_DEBUG"] = "true"

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
  config.debug = true # Turn off debug for cleaner interaction
end

# Check if we're properly configured
unless Agents.configuration.configured?
  puts "❌ No API keys configured. Please set OPENAI_API_KEY environment variable."
  puts "   Example: export OPENAI_API_KEY=your_key_here"
  exit 1
end

# Create shared context for the conversation
context = AirlineContext.new

# Start with triage agent
current_agent = TriageAgent.new(context: context)
SecureRandom.hex(8)

puts "=" * 60
puts "🎯 Welcome to Interactive Airline Customer Service!"
puts "=" * 60
puts
puts "You're chatting with our AI customer service system."
puts "The system has multiple specialized agents:"
puts "• Triage Agent - Routes your requests to the right specialist"
puts "• FAQ Agent - Answers questions about baggage, seats, wifi, etc."
puts "• Seat Booking Agent - Handles seat changes and updates"
puts
puts "Type 'exit' to quit, 'context' to see shared context, 'switch triage/faq/seat' to change agents"
puts "=" * 60
puts

loop do
  # Show current agent
  print "\n[#{current_agent.class.name.split("::").last}] You: "

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

  when /^switch\s+(triage|faq|seat)/
    agent_type = Regexp.last_match(1)
    case agent_type
    when "triage"
      current_agent = TriageAgent.new(context: context)
      puts "\n🔄 Switched to Triage Agent"
    when "faq"
      current_agent = FaqAgent.new(context: context)
      puts "\n🔄 Switched to FAQ Agent"
    when "seat"
      # Assign flight number if switching to seat booking
      context.assign_flight_number! unless context.flight_number
      current_agent = SeatBookingAgent.new(context: context)
      puts "\n🔄 Switched to Seat Booking Agent"
      puts "Flight number assigned: #{context.flight_number}" if context.flight_number
    end
    next

  when ""
    next
  end

  # Get agent response
  begin
    puts "\n[#{current_agent.class.name.split("::").last}] Agent: "
    print "🤔 Thinking... "
    $stdout.flush

    agent_response = current_agent.call(user_input)

    print "\r#{" " * 15}\r" # Clear "Thinking..."
    puts agent_response.content

    # Handle automatic handoffs
    if agent_response.handoff?
      handoff = agent_response.handoff_result
      target_class = handoff.target_agent_class

      puts "\n🔄 Transferring to #{target_class.name.split("::").last}..."

      # Special handling for seat booking - assign flight number
      if target_class == SeatBookingAgent
        context.assign_flight_number! unless context.flight_number
        puts "Flight number assigned: #{context.flight_number}" if context.flight_number
      end

      # Create new agent with shared context
      current_agent = target_class.new(context: context)
    end
  rescue StandardError => e
    print "\r#{" " * 15}\r" # Clear "Thinking..."
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
