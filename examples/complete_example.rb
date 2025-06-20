#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../lib/agents"

# Configure the SDK
Agents.configure do |config|
  config.openai_api_key = ENV['OPENAI_API_KEY']
  config.default_provider = :openai
  config.default_model = "gpt-4o-mini"
  config.debug = true
end

# Configure tracing for visibility
Agents.configure_tracing(
  enabled: true,
  console_output: true
)

# Example tools
class WeatherTool < Agents::ToolBase
  name "get_weather"
  description "Get current weather for a city"
  param :city, "string", "City name", required: true
  param :units, "string", "Temperature units (celsius/fahrenheit)", required: false

  def perform(city:, units: "celsius", context: nil)
    conditions = ["sunny", "cloudy", "rainy", "partly cloudy", "stormy"]
    temp = rand(10..30)
    temp = (temp * 9/5) + 32 if units.downcase == "fahrenheit"
    unit_symbol = units.downcase == "fahrenheit" ? "°F" : "°C"
    
    "Weather in #{city}: #{temp}#{unit_symbol}, #{conditions.sample}"
  end
end

class EmailTool < Agents::ToolBase
  name "send_email"
  description "Send an email to a customer"
  param :to, "string", "Email address", required: true
  param :subject, "string", "Email subject", required: true
  param :body, "string", "Email body", required: true

  def perform(to:, subject:, body:, context: nil)
    # Simulate email sending
    "Email sent successfully to #{to} with subject: #{subject}"
  end
end

class BookingTool < Agents::ToolBase
  name "book_flight"
  description "Book a flight for a customer"
  param :origin, "string", "Origin airport code", required: true
  param :destination, "string", "Destination airport code", required: true
  param :date, "string", "Travel date (YYYY-MM-DD)", required: true
  param :passengers, "integer", "Number of passengers", required: false

  def perform(origin:, destination:, date:, passengers: 1, context: nil)
    booking_ref = "RB#{rand(100000..999999)}"
    "Flight booked! Reference: #{booking_ref} for #{passengers} passenger(s) from #{origin} to #{destination} on #{date}"
  end
end

# Custom context for preserving customer information
class CustomerContext < Agents::Context
  attr_accessor :customer_name, :customer_email, :booking_history

  def initialize(data = {})
    super(data)
    @customer_name = nil
    @customer_email = nil
    @booking_history = []
  end
end

# Define agents in proper order to avoid forward reference issues
class CustomerServiceAgent < Agents::Agent
  name "Customer Service Representative"
  instructions <<~PROMPT
    You are a helpful customer service representative. Route customers to the appropriate specialists:
    - For weather questions, transfer to WeatherAgent
    - For flight bookings, transfer to BookingAgent
    
    You can also handle general inquiries and send emails.
  PROMPT
  provider :openai
  model "gpt-4o-mini"

  uses EmailTool
  # handoffs will be defined after all classes are created
end

class WeatherAgent < Agents::Agent
  name "Weather Specialist"
  instructions <<~PROMPT
    You are a weather specialist. Provide accurate weather information using the weather tool.
    Always be helpful and informative about weather conditions.
  PROMPT
  provider :openai
  model "gpt-4o-mini"

  uses WeatherTool
end

class BookingAgent < Agents::Agent
  name "Flight Booking Specialist"
  instructions <<~PROMPT
    You are a flight booking specialist. Help customers book flights and manage their travel plans.
    Use the booking tool to process reservations. Always confirm details before booking.
  PROMPT
  provider :openai
  model "gpt-4o-mini"

  uses BookingTool, EmailTool
end

# Set up handoffs after all classes are defined
CustomerServiceAgent.class_eval { handoffs WeatherAgent, BookingAgent }
WeatherAgent.class_eval { handoffs CustomerServiceAgent }
BookingAgent.class_eval { handoffs CustomerServiceAgent }

# Demo scenarios
def run_scenario(title, message, runner)
  puts "\n" + "=" * 60
  puts "📋 SCENARIO: #{title}"
  puts "=" * 60
  puts "User: #{message}"
  puts "-" * 60
  
  response = runner.process(message)
  puts "Response: #{response}"
  
  # Show agent transitions
  if runner.context.agent_transitions.any?
    puts "\n🔄 Agent Transitions:"
    runner.context.agent_transitions.each do |transition|
      puts "  #{transition[:from]} → #{transition[:to]}: #{transition[:reason]}"
    end
  end
  
  puts "=" * 60
end

# Main execution
if ENV['OPENAI_API_KEY']
  puts "🤖 Ruby Agents SDK - Complete Example"
  puts "🚀 Demonstrating multi-agent workflows with tools and handoffs"
  
  # Create context and runner
  context = CustomerContext.new
  runner = Agents::Runner.new(initial_agent: CustomerServiceAgent, context: context)
  
  # Run multiple scenarios
  scenarios = [
    ["Weather Query", "What's the weather like in Paris?"],
    ["Flight Booking", "I need to book a flight from NYC to LAX for tomorrow"],
    ["Complex Request", "Can you check the weather in Tokyo and then book me a flight there from San Francisco for next week?"],
    ["Customer Service", "I need help with my booking and want to receive an email confirmation to john@example.com"]
  ]
  
  scenarios.each do |title, message|
    run_scenario(title, message, runner)
    # Reset context for next scenario
    runner.context.clear_transitions
  end
  
  puts "\n✅ Complete example finished successfully!"
  puts "💡 Try modifying the agents, tools, or scenarios to see different behaviors"
  
else
  puts "❌ Please set OPENAI_API_KEY environment variable to run this example"
  puts "   export OPENAI_API_KEY=your-api-key-here"
end