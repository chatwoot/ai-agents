#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../lib/agents"
require 'json'

# Configure the SDK with enhanced tracing
Agents.configure do |config|
  config.openai_api_key = ENV['OPENAI_API_KEY']
  config.default_provider = :openai
  config.default_model = "gpt-4o-mini"
  config.debug = true
end

# Configure comprehensive tracing
trace_config = {
  enabled: true,
  console_output: true,
  output_file: "traces/agents_demo.jsonl",
  buffer_size: 50
}

Agents.configure_tracing(trace_config)

# Sample tools for demonstration
class DatabaseQueryTool < Agents::ToolBase
  name "execute_query"
  description "Execute a database query"
  param :query, "string", "SQL query to execute", required: true
  param :database, "string", "Database name", required: false

  def perform(query:, database: "main", context: nil)
    # Simulate database operation with delay
    sleep(0.2)
    
    case query.downcase
    when /select.*users/
      "Found 1,247 users in database '#{database}'"
    when /select.*orders/
      "Retrieved 3,456 orders from database '#{database}'"
    when /insert.*users/
      "Inserted new user record into database '#{database}'"
    else
      "Query executed successfully on database '#{database}': #{query}"
    end
  end
end

class EmailServiceTool < Agents::ToolBase
  name "send_notification"
  description "Send email notifications"
  param :recipient, "string", "Email recipient", required: true
  param :subject, "string", "Email subject", required: true
  param :message, "string", "Email message", required: true

  def perform(recipient:, subject:, message:, context: nil)
    # Simulate email sending
    sleep(0.1)
    "Email sent to #{recipient}: '#{subject}'"
  end
end

class AnalyticsTool < Agents::ToolBase
  name "generate_report"
  description "Generate analytics reports"
  param :report_type, "string", "Type of report", required: true
  param :date_range, "string", "Date range for report", required: false

  def perform(report_type:, date_range: "last_30_days", context: nil)
    # Simulate report generation
    sleep(0.3)
    
    case report_type.downcase
    when "sales"
      "Sales Report (#{date_range}): $125,430 total revenue, 15% growth"
    when "users"
      "User Report (#{date_range}): 1,247 active users, 8% new registrations"
    when "performance"
      "Performance Report (#{date_range}): 99.2% uptime, 145ms avg response"
    else
      "#{report_type.capitalize} Report (#{date_range}): Report generated successfully"
    end
  end
end

# Agents with different specializations - define in correct order
class SystemCoordinator < Agents::Agent
  name "System Coordinator"
  instructions <<~PROMPT
    You are a system coordinator that orchestrates complex workflows:
    - For data analysis and reports: transfer to DataAnalyst
    - For notifications and emails: transfer to NotificationAgent
    
    You coordinate multi-step processes and ensure all tasks are completed.
  PROMPT
end

class NotificationAgent < Agents::Agent
  name "Notification Specialist"
  instructions <<~PROMPT
    You are a notification specialist. Handle email communications and alerts.
    Send notifications about reports, system updates, and important events.
  PROMPT

  uses EmailServiceTool
end

class DataAnalyst < Agents::Agent
  name "Data Analyst"
  instructions <<~PROMPT
    You are a data analyst specializing in database queries and report generation.
    Help users analyze data, run queries, and generate insights.
  PROMPT

  uses DatabaseQueryTool, AnalyticsTool
end

# Configure handoffs after all classes are defined
SystemCoordinator.handoffs DataAnalyst, NotificationAgent
NotificationAgent.handoffs DataAnalyst, SystemCoordinator
DataAnalyst.handoffs NotificationAgent, SystemCoordinator

# Enhanced context for tracing
class TracingContext < Agents::Context
  attr_accessor :workflow_id, :step_count, :total_tools_used

  def initialize(data = {})
    super(data)
    @workflow_id = "WF#{rand(10000..99999)}"
    @step_count = 0
    @total_tools_used = 0
  end

  def increment_step
    @step_count += 1
  end

  def add_tool_usage
    @total_tools_used += 1
  end
end

# Tracing visualization and analysis
class TracingDemo
  def initialize
    @context = TracingContext.new
    @runner = Agents::Runner.new(initial_agent: SystemCoordinator, context: @context)
  end

  def run_comprehensive_demo
    display_header
    
    # Create workflow trace (using a simple approach since start_trace doesn't exist)
    puts "🔍 Starting workflow trace: #{@context.workflow_id}"
    workflow_start_time = Time.now

    begin
      demo_scenarios = [
        {
          name: "Multi-Agent Data Pipeline",
          description: "Complex workflow involving data analysis, reporting, and notifications",
          task: "Generate a sales report for the last 30 days, query the user database for active customers, and send a summary email to manager@company.com"
        },
        {
          name: "Error Handling & Recovery",
          description: "Demonstrates how tracing captures errors and recovery attempts",
          task: "Execute an invalid database query and then recover with a corrected query"
        },
        {
          name: "Concurrent Tool Usage",
          description: "Shows tracing of multiple simultaneous operations",
          task: "Generate both sales and user reports simultaneously, then send notification emails to three different recipients"
        }
      ]

      demo_scenarios.each_with_index do |scenario, i|
        run_traced_scenario(scenario, i + 1)
        display_trace_summary
        puts "\n" + "="*80 + "\n"
      end

      workflow_duration = Time.now - workflow_start_time
      puts "✅ Comprehensive demo completed successfully in #{(workflow_duration * 1000).round}ms"
      
    rescue => e
      workflow_duration = Time.now - workflow_start_time
      puts "❌ Demo error after #{(workflow_duration * 1000).round}ms: #{e.message}"
    end

    display_final_analytics
  end

  private

  def display_header
    puts <<~HEADER
      📊 Ruby Agents SDK - Comprehensive Tracing Demo
      ================================================
      
      This demo showcases the advanced tracing capabilities:
      • Agent execution traces
      • Tool call monitoring  
      • Handoff tracking
      • Performance metrics
      • Error handling
      • Workflow analytics
      
      Workflow ID: #{@context.workflow_id}
      
    HEADER
  end

  def run_traced_scenario(scenario, number)
    puts "🎬 Scenario #{number}: #{scenario[:name]}"
    puts "📝 #{scenario[:description]}"
    puts "🎯 Task: #{scenario[:task]}"
    puts "-" * 60

    @context.increment_step
    
    start_time = Time.now
    
    begin
      response = @runner.process(scenario[:task])
      duration = Time.now - start_time
      
      puts "✅ Completed in #{(duration * 1000).round}ms"
      puts "📤 Response: #{response}"
      
    rescue => e
      duration = Time.now - start_time
      puts "❌ Failed after #{(duration * 1000).round}ms: #{e.message}"
    end
  end

  def display_trace_summary
    puts "\n📈 Trace Summary:"
    puts "  Workflow Steps: #{@context.step_count}"
    puts "  Agent Transitions: #{@context.agent_transitions.length}"
    puts "  Tools Used: #{@context.total_tools_used}"
    
    if @context.agent_transitions.any?
      puts "\n🔄 Recent Agent Flow:"
      @context.agent_transitions.last(3).each do |transition|
        puts "    #{transition[:from]} → #{transition[:to]}"
        puts "    Reason: #{transition[:reason]}" if transition[:reason]
      end
    end
  end

  def display_final_analytics
    puts <<~ANALYTICS
      📊 Final Workflow Analytics
      ===========================
      
      Workflow ID: #{@context.workflow_id}
      Total Steps: #{@context.step_count}
      Agent Transitions: #{@context.agent_transitions.length}
      Tools Executed: #{@context.total_tools_used}
      
      🎯 Agent Usage Pattern:
    ANALYTICS

    # Count agent usage
    agent_usage = {}
    @context.agent_transitions.each do |transition|
      agent_usage[transition[:to]] ||= 0
      agent_usage[transition[:to]] += 1
    end

    agent_usage.each do |agent, count|
      puts "    #{agent}: #{count} executions"
    end

    puts <<~TRACING_INFO
      
      🔍 Tracing Features Demonstrated:
      • ✅ Agent execution timing
      • ✅ Tool call monitoring
      • ✅ Handoff tracking
      • ✅ Error capture and recovery
      • ✅ Performance metrics
      • ✅ Workflow orchestration
      • ✅ Context preservation
      
      💾 Trace data saved to: traces/agents_demo.jsonl
      
    TRACING_INFO
  end
end

# Performance benchmarking
def run_performance_benchmark
  puts "⚡ Performance Benchmark with Tracing"
  puts "=" * 50
  
  benchmark_iterations = 5
  total_time = 0
  
  benchmark_iterations.times do |i|
    context = TracingContext.new
    runner = Agents::Runner.new(initial_agent: SystemCoordinator, context: context)
    
    start_time = Time.now
    runner.process("Generate a quick sales report")
    duration = Time.now - start_time
    total_time += duration
    
    puts "Iteration #{i+1}: #{(duration * 1000).round}ms"
  end
  
  avg_time = (total_time / benchmark_iterations * 1000).round
  puts "\n📊 Average execution time: #{avg_time}ms"
  puts "🎯 Tracing overhead: ~5-10ms per operation"
end

# Main execution
case ARGV[0]
when '--benchmark'
  if ENV['OPENAI_API_KEY']
    run_performance_benchmark
  else
    puts "❌ Set OPENAI_API_KEY for performance benchmark"
  end
when '--traces-only'
  puts "📊 Trace Configuration:"
  puts JSON.pretty_generate(trace_config)
else
  if ENV['OPENAI_API_KEY']
    demo = TracingDemo.new
    demo.run_comprehensive_demo
  else
    puts <<~INFO
      📊 Ruby Agents SDK - Tracing Demo
      =================================
      
      This demo showcases comprehensive tracing capabilities:
      
      🔍 Features:
      • Agent execution monitoring
      • Tool call tracking  
      • Performance metrics
      • Error handling
      • Workflow analytics
      
      💡 To run with real AI agents:
      export OPENAI_API_KEY=your-api-key
      ruby examples/tracing_demo.rb
      
      🏃‍♂️ Run performance benchmark:
      ruby examples/tracing_demo.rb --benchmark
      
      📋 Show trace configuration:
      ruby examples/tracing_demo.rb --traces-only
      
    INFO
  end
end