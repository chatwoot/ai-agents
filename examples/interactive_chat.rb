#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../lib/agents"
require 'io/console'

# Configure the SDK
Agents.configure do |config|
  config.openai_api_key = ENV['OPENAI_API_KEY']
  config.default_provider = :openai
  config.default_model = "gpt-4o-mini"
end

# Configure tracing with live updates
Agents.configure_tracing(
  enabled: true,
  console_output: true
)

# Interactive tools
class CalculatorTool < Agents::ToolBase
  name "calculate"
  description "Perform mathematical calculations"
  param :expression, "string", "Mathematical expression to evaluate", required: true

  def perform(expression:, context: nil)
    begin
      # Simple safe evaluation for basic math
      result = eval(expression.gsub(/[^0-9+\-*\/\.\(\)\s]/, ''))
      "#{expression} = #{result}"
    rescue => e
      "Error calculating '#{expression}': #{e.message}"
    end
  end
end

class TimeTool < Agents::ToolBase
  name "get_time"
  description "Get current time in different timezones"
  param :timezone, "string", "Timezone (e.g., UTC, EST, PST)", required: false

  def perform(timezone: "local", context: nil)
    case timezone.downcase
    when "utc"
      "Current UTC time: #{Time.now.utc.strftime('%Y-%m-%d %H:%M:%S UTC')}"
    when "est"
      "Current EST time: #{(Time.now - 5*3600).strftime('%Y-%m-%d %H:%M:%S EST')}"
    when "pst"
      "Current PST time: #{(Time.now - 8*3600).strftime('%Y-%m-%d %H:%M:%S PST')}"
    else
      "Current local time: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}"
    end
  end
end

class NoteTool < Agents::ToolBase
  name "take_note"
  description "Take a note and store it in the conversation context"
  param :note, "string", "The note to store", required: true
  param :category, "string", "Category for the note", required: false

  def perform(note:, category: "general", context: nil)
    if context
      context[:notes] ||= []
      context[:notes] << {
        content: note,
        category: category,
        timestamp: Time.now
      }
      "Note saved: #{note} (Category: #{category})"
    else
      "Note: #{note}"
    end
  end
end

# Define agents in correct order to avoid forward reference issues
class GeneralAssistant < Agents::Agent
  name "General Assistant"
  instructions <<~PROMPT
    You are a helpful general assistant. Route users to specialists:
    - For math problems, calculations, or mathematical concepts: transfer to MathAgent
    - For time, scheduling, or timezone questions: transfer to TimeAgent
    
    You can also take notes and have general conversations.
  PROMPT
  
  uses NoteTool
end

class MathAgent < Agents::Agent
  name "Mathematics Expert"
  instructions <<~PROMPT
    You are a mathematics expert. Help users with calculations, mathematical concepts, and problem-solving.
    Use the calculator tool for computations. Explain your reasoning when solving problems.
  PROMPT
  
  uses CalculatorTool
end

class TimeAgent < Agents::Agent
  name "Time & Scheduling Assistant"
  instructions <<~PROMPT
    You are a time and scheduling assistant. Help users with time-related queries, timezone conversions,
    and scheduling. Use the time tool to get current times.
  PROMPT
  
  uses TimeTool, NoteTool
end

# Set up handoffs after all classes are defined
GeneralAssistant.class_eval { handoffs MathAgent, TimeAgent }
MathAgent.class_eval { handoffs GeneralAssistant }
TimeAgent.class_eval { handoffs GeneralAssistant }

# Interactive chat interface
class InteractiveChat
  def initialize(runner)
    @runner = runner
    @session_active = true
  end

  def start
    display_welcome
    display_help
    
    while @session_active
      print_prompt
      input = get_user_input
      
      case input.strip.downcase
      when '/help'
        display_help
      when '/status'
        display_status
      when '/notes'
        display_notes
      when '/clear'
        clear_screen
      when '/quit', '/exit'
        @session_active = false
        puts "👋 Goodbye! Thanks for using Ruby Agents SDK!"
      else
        process_message(input) unless input.strip.empty?
      end
    end
  end

  private

  def display_welcome
    clear_screen
    puts <<~WELCOME
      🤖 Ruby Agents SDK - Interactive Chat
      =====================================
      
      Welcome to the interactive multi-agent chat system!
      
      Available agents:
      • 🧮 Mathematics Expert - Calculations and math problems
      • ⏰ Time Assistant - Time zones and scheduling
      • 💬 General Assistant - General conversation and routing
      
      Type your message and watch agents collaborate automatically!
    WELCOME
  end

  def display_help
    puts <<~HELP
      
      📖 Available Commands:
      ----------------------
      /help     - Show this help message
      /status   - Show current session status
      /notes    - Show saved notes
      /clear    - Clear the screen
      /quit     - Exit the chat
      
      💡 Example queries:
      - "What's 15 * 24 + 30?"
      - "What time is it in UTC?"
      - "Take a note: Meeting tomorrow at 3pm"
      - "Help me calculate compound interest"
      
    HELP
  end

  def display_status
    context = @runner.context
    puts <<~STATUS
      
      📊 Session Status:
      ------------------
      Current Agent: #{@runner.current_agent.class.name}
      Total Interactions: #{context.agent_transitions.length}
      Notes Saved: #{context[:notes]&.length || 0}
      
    STATUS
    
    if context.agent_transitions.any?
      puts "Recent Agent Transitions:"
      context.agent_transitions.last(3).each do |transition|
        puts "  #{transition[:from]} → #{transition[:to]}"
      end
    end
  end

  def display_notes
    notes = @runner.context[:notes]
    if notes && notes.any?
      puts "\n📝 Saved Notes:"
      puts "-" * 20
      notes.each_with_index do |note, i|
        timestamp = note[:timestamp].strftime('%H:%M:%S')
        puts "#{i+1}. [#{timestamp}] #{note[:content]} (#{note[:category]})"
      end
    else
      puts "\n📝 No notes saved yet."
    end
    puts
  end

  def print_prompt
    print "\n💬 You: "
  end

  def get_user_input
    input = gets
    return 'quit' if input.nil? # Handle EOF gracefully
    input.chomp
  end

  def process_message(message)
    puts "\n🤖 Processing..."
    
    start_time = Time.now
    response = @runner.process(message)
    duration = ((Time.now - start_time) * 1000).round
    
    puts "\n🤖 Agent: #{response}"
    puts "\n⏱️  Response time: #{duration}ms"
    
    # Show any agent transitions that occurred
    recent_transitions = @runner.context.agent_transitions.last(1)
    if recent_transitions.any?
      transition = recent_transitions.first
      if transition[:from] != transition[:to]
        puts "🔄 Routed: #{transition[:from]} → #{transition[:to]}"
      end
    end
  end

  def clear_screen
    system('clear') || system('cls')
  end
end

# Main execution
if ENV['OPENAI_API_KEY']
  puts "🚀 Starting Interactive Chat..."
  
  context = Agents::Context.new
  runner = Agents::Runner.new(initial_agent: GeneralAssistant, context: context)
  
  chat = InteractiveChat.new(runner)
  chat.start
  
else
  puts "❌ Please set OPENAI_API_KEY environment variable to run this example"
  puts "   export OPENAI_API_KEY=your-api-key-here"
end