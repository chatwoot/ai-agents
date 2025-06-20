#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../lib/agents"

# Simple weather tool
class WeatherTool < Agents::ToolBase
  name "get_weather"
  description "Get current weather for a city"
  param :city, "string", "City name", required: true

  def perform(city:, context: nil)
    # Simulate API call
    conditions = ["sunny", "cloudy", "rainy", "partly cloudy"]
    temp = rand(10..30)
    "Weather in #{city}: #{temp}°C, #{conditions.sample}"
  end
end

# Weather specialist agent
class WeatherAgent < Agents::Agent
  name "Weather Assistant"
  instructions "You are a helpful weather assistant. Use the weather tool to get current conditions."
  provider :openai
  model "gpt-4o-mini"

  uses WeatherTool
end

# Triage agent that routes to specialists
class TriageAgent < Agents::Agent
  name "Assistant"
  instructions "Route weather requests to the Weather Assistant. For weather questions, always transfer."
  provider :openai
  model "gpt-4o-mini"

  handoffs WeatherAgent
end

# Configure the SDK
Agents.configure do |config|
  config.openai_api_key = ENV['OPENAI_API_KEY']
  config.default_provider = :openai
  config.default_model = "gpt-4o-mini"
end

# Example usage
puts "🤖 Multi-Agent Weather System"
puts "=" * 40

if ENV['OPENAI_API_KEY']
  # Create context and runner
  context = Agents::Context.new
  runner = Agents::Runner.new(initial_agent: TriageAgent, context: context)

  # Process a weather request
  response = runner.process("What's the weather like in Tokyo?")
  puts "Response: #{response}"
  
  # Show agent transitions
  puts "\nAgent transitions:"
  context.agent_transitions.each do |transition|
    puts "  #{transition[:from]} → #{transition[:to]}: #{transition[:reason]}"
  end
else
  puts "❌ Set OPENAI_API_KEY environment variable to run this example"
end