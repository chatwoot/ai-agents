#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../lib/agents"
require 'date'
require 'json'

# Configure the SDK
Agents.configure do |config|
  config.openai_api_key = ENV['OPENAI_API_KEY']
  config.default_provider = :openai
  config.default_model = "gpt-4o-mini"
end

# Configure enhanced tracing
Agents.configure_tracing(
  enabled: true,
  console_output: true
)

# Flight booking tools
class FlightSearchTool < Agents::ToolBase
  name "search_flights"
  description "Search for available flights"
  param :origin, "string", "Origin airport code (e.g., LAX, JFK)", required: true
  param :destination, "string", "Destination airport code", required: true
  param :departure_date, "string", "Departure date (YYYY-MM-DD)", required: true
  param :return_date, "string", "Return date (YYYY-MM-DD)", required: false
  param :passengers, "integer", "Number of passengers", required: false

  def perform(origin:, destination:, departure_date:, return_date: nil, passengers: 1, context: nil)
    # Simulate flight search
    flights = generate_mock_flights(origin, destination, departure_date, return_date, passengers)
    context[:available_flights] = flights if context
    
    format_flight_results(flights)
  end

  private

  def generate_mock_flights(origin, destination, departure_date, return_date, passengers)
    airlines = ["American Airlines", "Delta", "United", "Southwest", "JetBlue"]
    
    outbound_flights = (1..3).map do |i|
      {
        flight_number: "#{airlines.sample[0..1].upcase}#{rand(100..999)}",
        airline: airlines.sample,
        origin: origin.upcase,
        destination: destination.upcase,
        departure_time: "#{rand(6..22).to_s.rjust(2, '0')}:#{['00', '15', '30', '45'].sample}",
        arrival_time: "#{rand(8..23).to_s.rjust(2, '0')}:#{['00', '15', '30', '45'].sample}",
        price: rand(200..800),
        duration: "#{rand(2..8)}h #{rand(0..59)}m",
        date: departure_date
      }
    end

    return_flights = return_date ? (1..3).map do |i|
      {
        flight_number: "#{airlines.sample[0..1].upcase}#{rand(100..999)}",
        airline: airlines.sample,
        origin: destination.upcase,
        destination: origin.upcase,
        departure_time: "#{rand(6..22).to_s.rjust(2, '0')}:#{['00', '15', '30', '45'].sample}",
        arrival_time: "#{rand(8..23).to_s.rjust(2, '0')}:#{['00', '15', '30', '45'].sample}",
        price: rand(200..800),
        duration: "#{rand(2..8)}h #{rand(0..59)}m",
        date: return_date
      }
    end : []

    { outbound: outbound_flights, return: return_flights, passengers: passengers }
  end

  def format_flight_results(flights)
    result = "✈️ Flight Search Results:\n\n"
    
    result += "📅 OUTBOUND FLIGHTS:\n"
    flights[:outbound].each_with_index do |flight, i|
      result += "#{i+1}. #{flight[:airline]} #{flight[:flight_number]}\n"
      result += "   #{flight[:origin]} → #{flight[:destination]}\n"
      result += "   #{flight[:date]} #{flight[:departure_time]} - #{flight[:arrival_time]} (#{flight[:duration]})\n"
      result += "   💰 $#{flight[:price]} per person\n\n"
    end

    if flights[:return].any?
      result += "📅 RETURN FLIGHTS:\n"
      flights[:return].each_with_index do |flight, i|
        result += "#{i+1}. #{flight[:airline]} #{flight[:flight_number]}\n"
        result += "   #{flight[:origin]} → #{flight[:destination]}\n"
        result += "   #{flight[:date]} #{flight[:departure_time]} - #{flight[:arrival_time]} (#{flight[:duration]})\n"
        result += "   💰 $#{flight[:price]} per person\n\n"
      end
    end

    result += "👥 For #{flights[:passengers]} passenger(s)\n"
    result
  end
end

class FlightBookingTool < Agents::ToolBase
  name "book_flight"
  description "Book a selected flight"
  param :outbound_flight_number, "integer", "Outbound flight number (1, 2, or 3)", required: true
  param :return_flight_number, "integer", "Return flight number (1, 2, or 3)", required: false
  param :passenger_name, "string", "Passenger full name", required: true
  param :passenger_email, "string", "Passenger email", required: true

  def perform(outbound_flight_number:, return_flight_number: nil, passenger_name:, passenger_email:, context: nil)
    available_flights = context&.dig(:available_flights)
    return "❌ No flights available. Please search for flights first." unless available_flights

    booking_ref = "RB#{rand(100000..999999)}"
    total_cost = 0

    booking_details = "🎫 BOOKING CONFIRMED!\n\n"
    booking_details += "📋 Confirmation: #{booking_ref}\n"
    booking_details += "👤 Passenger: #{passenger_name}\n"
    booking_details += "📧 Email: #{passenger_email}\n\n"

    # Book outbound flight
    if outbound_flight_number >= 1 && outbound_flight_number <= 3
      flight = available_flights[:outbound][outbound_flight_number - 1]
      booking_details += "✈️ OUTBOUND FLIGHT:\n"
      booking_details += format_booked_flight(flight)
      total_cost += flight[:price]
    end

    # Book return flight if specified
    if return_flight_number && return_flight_number >= 1 && return_flight_number <= 3
      flight = available_flights[:return][return_flight_number - 1]
      booking_details += "\n✈️ RETURN FLIGHT:\n"
      booking_details += format_booked_flight(flight)
      total_cost += flight[:price]
    end

    booking_details += "\n💰 TOTAL COST: $#{total_cost * available_flights[:passengers]}\n"
    booking_details += "\n📱 Check-in opens 24 hours before departure"
    
    # Store booking in context
    context[:last_booking] = {
      confirmation: booking_ref,
      passenger: passenger_name,
      email: passenger_email,
      total_cost: total_cost * available_flights[:passengers]
    } if context

    booking_details
  end

  private

  def format_booked_flight(flight)
    "   #{flight[:airline]} #{flight[:flight_number]}\n" +
    "   #{flight[:origin]} → #{flight[:destination]}\n" +
    "   #{flight[:date]} #{flight[:departure_time]} - #{flight[:arrival_time]}\n" +
    "   Duration: #{flight[:duration]}\n"
  end
end

class CustomerLookupTool < Agents::ToolBase
  name "lookup_customer"
  description "Look up customer information and booking history"
  param :email, "string", "Customer email address", required: true

  def perform(email:, context: nil)
    # Simulate customer lookup
    mock_customers = {
      "john@example.com" => {
        name: "John Smith",
        frequent_flyer: "AA1234567",
        preference: "Aisle seat",
        recent_bookings: ["RB123456", "RB789012"]
      },
      "sarah@example.com" => {
        name: "Sarah Johnson", 
        frequent_flyer: "DL9876543",
        preference: "Window seat",
        recent_bookings: ["RB345678"]
      }
    }

    customer = mock_customers[email.downcase]
    
    if customer
      context[:customer_info] = customer if context
      "✅ Customer found: #{customer[:name]}\n" +
      "🎫 Frequent Flyer: #{customer[:frequent_flyer]}\n" +
      "💺 Preference: #{customer[:preference]}\n" +
      "📋 Recent bookings: #{customer[:recent_bookings].join(', ')}"
    else
      "❌ Customer not found. This appears to be a new customer."
    end
  end
end

# Define agents in proper order to avoid forward reference issues
class CustomerServiceAgent < Agents::Agent
  name "Customer Service Representative"
  instructions <<~PROMPT
    You are a friendly airline customer service representative. Help customers with their travel needs:
    
    - For flight searches: transfer to FlightSearchAgent
    - For bookings and reservations: transfer to FlightBookingAgent
    - For existing customer inquiries: use customer lookup tool
    
    Always be helpful, professional, and ensure customers have a great experience.
  PROMPT

  uses CustomerLookupTool
end

class FlightSearchAgent < Agents::Agent
  name "Flight Search Specialist"
  instructions <<~PROMPT
    You are a flight search specialist. Help customers find the perfect flights for their travel needs.
    
    Use the flight search tool to find available flights. Always ask for:
    - Origin and destination airports
    - Travel dates
    - Number of passengers
    
    Present options clearly and help customers choose the best flights for their needs.
  PROMPT

  uses FlightSearchTool
end

class FlightBookingAgent < Agents::Agent
  name "Flight Booking Specialist" 
  instructions <<~PROMPT
    You are a flight booking specialist. Complete flight reservations for customers.
    
    Use the booking tool to reserve flights. Always collect:
    - Selected flight numbers
    - Passenger full name
    - Contact email
    
    Confirm all details before booking and provide clear confirmation information.
  PROMPT

  uses FlightBookingTool, CustomerLookupTool
end

# Set up handoffs after all classes are defined
CustomerServiceAgent.class_eval { handoffs FlightSearchAgent, FlightBookingAgent }
FlightSearchAgent.class_eval { handoffs FlightBookingAgent, CustomerServiceAgent }
FlightBookingAgent.class_eval { handoffs FlightSearchAgent, CustomerServiceAgent }

# Enhanced flight booking context
class FlightContext < Agents::Context
  attr_accessor :customer_info, :available_flights, :last_booking

  def initialize(data = {})
    super(data)
    @customer_info = nil
    @available_flights = nil
    @last_booking = nil
  end

  def booking_summary
    return "No active booking" unless @last_booking
    
    "Recent booking: #{@last_booking[:confirmation]} for #{@last_booking[:passenger]} ($#{@last_booking[:total_cost]})"
  end
end

# Interactive flight booking interface
class FlightBookingInterface
  def initialize
    @context = FlightContext.new
    @runner = Agents::Runner.new(initial_agent: CustomerServiceAgent, context: @context)
    @session_active = true
  end

  def start
    display_welcome
    
    while @session_active
      print_prompt
      input = get_user_input.strip
      
      case input.downcase
      when '/help'
        display_help
      when '/status'
        display_status
      when '/demo'
        run_demo_scenarios
      when '/quit', '/exit'
        @session_active = false
        puts "✈️ Thank you for using Ruby Airlines! Safe travels! ✈️"
      when ''
        # Skip empty input
      else
        process_booking_request(input)
      end
    end
  end

  private

  def display_welcome
    puts <<~WELCOME
      ✈️ Welcome to Ruby Airlines Booking System
      ==========================================
      
      🤖 AI-Powered Flight Booking with Multi-Agent Intelligence
      
      Our AI agents will help you:
      • 🔍 Search for flights
      • 📅 Book reservations  
      • 👤 Manage customer information
      • 💼 Handle special requests
      
      Just tell us what you need in natural language!
      
    WELCOME
    display_help
  end

  def display_help
    puts <<~HELP
      💡 What can I help you with?
      ----------------------------
      • "I need a flight from LAX to JFK on December 25th"
      • "Book me a round trip from San Francisco to New York"
      • "Look up my booking for john@example.com"
      • "Find flights for 2 passengers next Friday"
      
      🎮 Commands:
      /help   - Show this help
      /status - Show booking status  
      /demo   - Run demo scenarios
      /quit   - Exit system
      
    HELP
  end

  def display_status
    puts <<~STATUS
      📊 Booking Session Status:
      --------------------------
      Current Agent: #{@runner.current_agent.class.name.split('::').last}
      Customer Info: #{@context.customer_info ? "✅ Loaded" : "❌ None"}
      Available Flights: #{@context.available_flights ? "✅ Found" : "❌ None"}
      Last Booking: #{@context.booking_summary}
      Agent Transitions: #{@context.agent_transitions.length}
      
    STATUS
  end

  def print_prompt
    print "\n🎫 Ruby Airlines: "
  end

  def get_user_input
    gets.chomp
  end

  def process_booking_request(message)
    puts "\n🤖 Processing your request..."
    
    start_time = Time.now
    
    begin
      response = @runner.process(message)
      duration = ((Time.now - start_time) * 1000).round
      
      puts "\n" + "=" * 60
      puts response
      puts "=" * 60
      puts "⏱️  Response time: #{duration}ms"
      
      # Show agent workflow
      if @context.agent_transitions.any?
        recent = @context.agent_transitions.last
        if recent[:from] != recent[:to]
          puts "🔄 Agent: #{recent[:from]} → #{recent[:to]}"
        end
      end
      
    rescue => e
      puts "❌ Error processing request: #{e.message}"
      puts "Please try again or contact support."
    end
  end

  def run_demo_scenarios
    puts "\n🎬 Running Demo Scenarios..."
    
    scenarios = [
      "I need a flight from Los Angeles to New York on January 15th for 2 passengers",
      "Book the first outbound flight and second return flight for John Smith, email john@example.com",
      "Look up booking information for sarah@example.com"
    ]
    
    scenarios.each_with_index do |scenario, i|
      puts "\n" + "🎭 Demo #{i+1}: #{scenario}"
      puts "-" * 50
      
      process_booking_request(scenario)
      
      sleep(1) # Brief pause between demos
    end
    
    puts "\n✅ Demo scenarios completed!"
  end
end

# Main execution
if ENV['OPENAI_API_KEY']
  puts "🚀 Starting Ruby Airlines Booking System..."
  
  interface = FlightBookingInterface.new
  interface.start
  
else
  puts <<~ERROR
    ❌ OpenAI API Key Required
    ==========================
    
    Please set your OpenAI API key to use this live demo:
    
    export OPENAI_API_KEY=your-api-key-here
    ruby examples/live_flight_booking.rb
    
    This demo showcases:
    • Multi-agent conversation flow
    • Real-time tool execution
    • Context preservation across agents
    • Production-ready error handling
    
  ERROR
end