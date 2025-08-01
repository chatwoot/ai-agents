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

    # Create thread-safe runner with all agents (triage first = default entry point)
    @runner = Agents::Runner.with_agents(
      @agents[:triage],
      @agents[:sales],
      @agents[:support]
    )

    # Setup real-time callbacks for UI feedback
    setup_callbacks

    @context = {}
    @current_status = ""

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

      # Clear any previous status and show agent is working
      clear_status_line
      print "🤖 Processing..."

      # Use the runner - it automatically determines the right agent from context
      result = @runner.run(user_input, context: @context)

      # Update our context with the returned context from Runner
      @context = result.context if result.respond_to?(:context) && result.context

      # Clear status and show response
      clear_status_line

      # Handle structured output from triage agent
      output = result.output || "[No output]"
      if @context[:current_agent] == "Triage Agent" && output.start_with?("{")
        begin
          structured = JSON.parse(output)
          # Display the greeting from structured response
          puts "🤖 #{structured["greeting"]}"
          if structured["intent_category"]
            puts "   [Intent: #{structured["intent_category"]}, Routing to: #{structured["recommended_agent"] || "TBD"}]"
          end
        rescue JSON::ParserError
          # Fall back to regular output if not valid JSON
          puts "🤖 #{output}"
        end
      else
        puts "🤖 #{output}"
      end

      puts
    end
  end

  private

  def setup_callbacks
    @runner.on_agent_thinking do |agent_name, _input|
      update_status("🧠 #{agent_name} is thinking...")
    end

    @runner.on_tool_start do |tool_name, _args|
      update_status("🔧 Using #{tool_name}...")
    end

    @runner.on_tool_complete do |tool_name, _result|
      update_status("✅ #{tool_name} completed")
    end

    @runner.on_agent_handoff do |from_agent, to_agent, _reason|
      update_status("🔄 Handoff: #{from_agent} → #{to_agent}")
    end
  end

  def update_status(message)
    clear_status_line
    print message
    $stdout.flush
  end

  def clear_status_line
    print "\r#{" " * 80}\r" # Clear the current line
    $stdout.flush
  end

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
