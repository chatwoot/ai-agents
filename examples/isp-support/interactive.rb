#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
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

      command_result = handle_command(user_input)
      break if command_result == :exit
      next if command_result == :handled || user_input.empty?

      # Determine which agent to use - either from context or triage agent
      current_agent = @context[:current_agent] || @triage_agent

      result = Agents::Runner.run(current_agent, user_input, context: @context)

      # Update our context with the returned context from Runner
      @context = result.context if result.respond_to?(:context) && result.context

      puts "🤖 #{result.output || "[No output]"}"

      puts
    end
  end

  private

  def handle_command(input)
    case input.downcase
    when "exit", "quit"
      dump_context_and_quit
      puts "👋 Goodbye!"
      :exit
    when "/help"
      show_help
      :handled
    when "/reset"
      @context.clear
      puts "🔄 Context reset. Starting fresh conversation."
      :handled
    when "/agents"
      show_agents
      :handled
    when "/tools"
      show_tools
      :handled
    when "/context"
      show_context
      :handled
    else
      :not_command # Not a command, continue with normal processing
    end
  end

  def dump_context_and_quit
    project_root = File.expand_path("../..", __dir__)
    tmp_directory = File.join(project_root, "tmp")

    # Ensure tmp directory exists
    Dir.mkdir(tmp_directory) unless Dir.exist?(tmp_directory)

    timestamp = Time.now.to_i
    context_filename = File.join(tmp_directory, "context-#{timestamp}.json")

    File.write(context_filename, JSON.pretty_generate(@context))

    puts "💾 Context saved to tmp/context-#{timestamp}.json"
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
