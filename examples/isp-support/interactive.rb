#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../../lib/agents"
require_relative "agents_factory"

# Simple ISP Customer Support Demo
class ISPSupportDemo
  def initialize
    # Configure the Agents SDK with API key
    Agents.configure do |config|
      config.openai_api_key = ENV["OPENAI_API_KEY"]
    end

    # Create agents
    @agents = ISPSupport::AgentsFactory.create_agents
    @triage_agent = @agents[:triage]
    @context = {}

    puts "🏢 Welcome to ISP Customer Support!"
    puts "Type '/help' for commands or 'exit' to quit."
    puts
  end

  def start
    loop do
      print "💬 You: "
      user_input = gets.chomp.strip

      break if handle_command(user_input)
      next if user_input.empty?

      # Run the triage agent - Runner handles all handoffs
      puts "DEBUG: About to call Runner..."
      result = Agents::Runner.run(@triage_agent, user_input, context: @context)
      puts "DEBUG: Result class: #{result.class}"
      puts "DEBUG: Result output: #{result.output.inspect}"
      puts "DEBUG: Result error: #{result.error.inspect}" if result.respond_to?(:error)
      puts "🤖 #{result.output || "[No output]"}"
      puts
    end
  end

  private

  def handle_command(input)
    case input.downcase
    when "exit", "quit"
      puts "👋 Goodbye!"
      return true
    when "/help"
      show_help
    when "/reset"
      @context.clear
      puts "🔄 Context reset. Starting fresh conversation."
    when "/agents"
      show_agents
    when "/tools"
      show_tools
    when "/context"
      show_context
    else
      return false # Not a command, continue with normal processing
    end

    puts
    false
  end

  def show_help
    puts "📋 Available Commands:"
    puts "  /help     - Show this help message"
    puts "  /reset    - Clear conversation context and start fresh"
    puts "  /agents   - List all available agents"
    puts "  /tools    - Show tools available to agents"
    puts "  /context  - Show current conversation context"
    puts "  exit/quit - End the session"
    puts
    puts "💡 Example customer requests:"
    puts "  - 'What's my current plan?' (try account ID: CUST001)"
    puts "  - 'I want to upgrade my internet'"
    puts "  - 'My internet is slow'"
  end

  def show_agents
    puts "🤖 Available Agents:"
    @agents.each do |key, agent|
      puts "  #{agent.name} - #{get_agent_description(key)}"
    end
  end

  def show_tools
    puts "🔧 Agent Tools:"
    @agents.each_value do |agent|
      puts "  #{agent.name}:"
      if agent.all_tools.empty?
        puts "    (no tools)"
      else
        agent.all_tools.each do |tool|
          puts "    - #{tool.name}: #{tool.description}"
        end
      end
    end
  end

  def show_context
    puts "📊 Current Context:"
    if @context.empty?
      puts "  (empty)"
    else
      @context.each do |key, value|
        puts "  #{key}: #{value}"
      end
    end
  end

  def get_agent_description(key)
    case key
    when :triage then "Routes customers to appropriate specialists"
    when :customer_info then "Handles account information and billing"
    when :sales then "Manages new sales and upgrades"
    when :support then "Provides technical support and troubleshooting"
    else "Unknown agent"
    end
  end
end

# Run the demo
ISPSupportDemo.new.start if __FILE__ == $PROGRAM_NAME
