#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../../lib/agents"

# Simple tracing demo
class TracingDemo
  def initialize
    # Configure the Agents SDK
    Agents.configure do |config|
      config.openai_api_key = ENV["OPENAI_API_KEY"] || "demo-key"
      config.default_model = "gpt-4o-mini"
    end

    # Create simple agents
    @triage = Agents::Agent.new(
      name: "Triage",
      instructions: "You help route customer inquiries to the right department"
    )

    @support = Agents::Agent.new(
      name: "Support",
      instructions: "You provide technical support"
    )

    # Register handoff relationship
    @triage.register_handoffs(@support)

    # Create runner with tracing enabled
    @runner = Agents::Runner.new([@triage, @support])
                            .with_tracing(service_name: "customer-support-demo")

    puts "🔍 OpenInference Tracing Demo"
    puts "Traces will be sent to: #{ENV["OTEL_EXPORTER_OTLP_ENDPOINT"] || "http://localhost:4318"}"
    puts
  end

  def run
    # Demo 1: Simple conversation
    puts "Demo 1: Single conversation"
    result = @runner.run("Hi, I need help with my internet connection")
    puts "Response: #{result.output}"
    puts

    # Demo 2: Session tracking
    puts "Demo 2: Session-tracked conversation"
    session_id = "demo-session-#{Time.now.to_i}"

    Agents::Tracing::SessionContext.with_session(session_id) do
      result1 = @runner.run("I have a billing question")
      puts "Response 1: #{result1.output}"

      result2 = @runner.run("What about technical support?", context: result1.context)
      puts "Response 2: #{result2.output}"
    end

    puts
    puts "✅ Demo completed! Check your tracing backend for traces."
    puts "   - CHAIN spans for overall conversations"
    puts "   - AGENT spans for individual agent executions"
    puts "   - TOOL spans for any tool calls"
    puts "   - Session ID '#{session_id}' links the second conversation"
  end
end

if __FILE__ == $0
  demo = TracingDemo.new
  demo.run
end
