#!/usr/bin/env ruby
# frozen_string_literal: true

# Basic usage example of the Agents gem
# This example shows how to create a simple tool and agent

# Add the lib directory to load path for development
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "agents"

# Configure the gem (you'll need to set OPENAI_API_KEY environment variable)
Agents.configure do |config|
  config.openai_api_key = ENV["OPENAI_API_KEY"]
  config.default_model = "gpt-4.1-mini"
  config.debug = true
end

# Check if we're properly configured
unless Agents.configuration.configured?
  puts "❌ No API keys configured. Please set OPENAI_API_KEY environment variable."
  puts "   Example: export OPENAI_API_KEY=your_key_here"
  exit 1
end

puts "✅ Agents configured with providers: #{Agents.configuration.available_providers.join(", ")}"

# Define a simple tool
class GreetingTool < Agents::Tool
  description "Generate a personalized greeting"
  param :name, String, "Person's name to greet"
  param :style, String, "Greeting style (formal, casual, funny)", required: false

  def execute(name:, style: "casual")
    case style.downcase
    when "formal"
      "Good day, #{name}. It is a pleasure to make your acquaintance."
    when "funny"
      "Hey there, #{name}! Hope you're having a more exciting day than a sloth in a hammock!"
    else
      "Hi #{name}! Nice to meet you!"
    end
  end
end

# Define a simple agent
class GreetingAgent < Agents::Agent
  name "Greeting Assistant"
  instructions "You are a friendly assistant that helps create personalized greetings. Use the greeting tool to generate appropriate greetings for people."

  uses GreetingTool
end

# Test the tool directly
puts "\n🔧 Testing tool directly:"
tool = GreetingTool.new
puts "Casual: #{tool.execute(name: "Alice")}"
puts "Formal: #{tool.execute(name: "Bob", style: "formal")}"
puts "Funny: #{tool.execute(name: "Charlie", style: "funny")}"

# Test the agent
puts "\n🤖 Testing agent:"
agent = GreetingAgent.new

# Simple conversation
puts "\n--- Conversation 1 ---"
response = agent.call("Please greet someone named Alice in a casual way")
puts "Agent: #{response}"

puts "\n--- Conversation 2 ---"
response = agent.call("Create a formal greeting for Mr. Johnson")
puts "Agent: #{response}"

puts "\n--- Conversation 3 ---"
response = agent.call("Give me a funny greeting for my friend Sam")
puts "Agent: #{response}"

# Test conversation history
puts "\n📝 Conversation history:"
agent.history.each_with_index do |turn, i|
  puts "Turn #{i + 1}:"
  puts "  User: #{turn[:user]}"
  puts "  Agent: #{turn[:assistant]}"
  puts "  Time: #{turn[:timestamp]}"
  puts
end

puts "✅ Example completed successfully!"
