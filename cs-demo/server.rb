#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "securerandom"
require "time"
require "webrick"
require_relative "../lib/agents"
require_relative "airline/agents_factory"

module CSDemo
  class App
    Event = Struct.new(:id, :type, :agent, :content, :metadata, :timestamp, keyword_init: true) do
      def to_h
        {
          id: id,
          type: type,
          agent: agent,
          content: content,
          metadata: metadata,
          timestamp: timestamp
        }
      end
    end

    def initialize
      configure_agents
      @agents = Airline::AgentsFactory.create_agents
      @runner = Agents::Runner.with_agents(*@agents.values)
      @states = {}
      @mutex = Mutex.new
      setup_callbacks
    end

    def bootstrap
      thread_id = SecureRandom.uuid
      state_for(thread_id)
      snapshot(thread_id)
    end

    def state(thread_id)
      snapshot(thread_id || bootstrap[:thread_id])
    end

    def reset(thread_id)
      @mutex.synchronize { @states.delete(thread_id) } if thread_id
      bootstrap
    end

    def message(thread_id, text)
      thread_id = SecureRandom.uuid if thread_id.nil? || thread_id.empty?
      state = state_for(thread_id)
      clean_text = text.to_s.strip
      return snapshot(thread_id) if clean_text.empty?

      state[:messages] << { role: "user", content: clean_text, timestamp: now_ms }
      before_context = Airline.public_context(state[:context][:state])

      result = @runner.run(clean_text, context: state[:context], max_turns: 12)
      state[:context] = result.context if result.context
      output = normalize_output(result.output)

      if result.error
        output = safe_error_message(result.error)
        record_event(thread_id, "error", state[:context][:current_agent] || "System", output)
      end

      state[:messages] << { role: "assistant", content: output, timestamp: now_ms }
      record_context_update(thread_id, before_context, Airline.public_context(state[:context][:state]))
      snapshot(thread_id)
    end

    def choose_seat(thread_id, seat)
      message(thread_id, "Please change my seat to #{seat}.")
    end

    private

    def configure_agents
      Agents.configure do |config|
        config.openai_api_key = ENV["OPENAI_API_KEY"]
        config.default_model = ENV.fetch("CS_DEMO_MODEL", "gpt-5.2")
      end
    end

    def setup_callbacks
      @runner.on_agent_thinking do |agent_name, input, run_context|
        thread_id = run_context.context[:thread_id]
        record_event(thread_id, "progress_update", agent_name, "#{agent_name} is thinking...", input: input)
      end

      @runner.on_tool_start do |tool_name, args, run_context|
        next if tool_name.to_s.start_with?("handoff_to_")

        thread_id = run_context.context[:thread_id]
        agent = run_context.context[:current_agent] || "Agent"
        record_event(thread_id, "tool_call", agent, tool_name, tool_args: args)
      end

      @runner.on_tool_complete do |tool_name, result, run_context|
        next if tool_name.to_s.start_with?("handoff_to_")

        thread_id = run_context.context[:thread_id]
        agent = run_context.context[:current_agent] || "Agent"
        record_event(thread_id, "tool_output", agent, tool_name, tool_result: result)
      end

      @runner.on_agent_handoff do |from_agent, to_agent, _reason, run_context|
        thread_id = run_context.context[:thread_id]
        record_event(
          thread_id,
          "handoff",
          from_agent,
          "#{from_agent} -> #{to_agent}",
          source_agent: from_agent,
          target_agent: to_agent
        )
      end
    end

    def state_for(thread_id)
      @mutex.synchronize do
        @states[thread_id] ||= {
          context: {
            thread_id: thread_id,
            state: Airline.initial_state,
            current_agent: @agents[:triage].name,
            conversation_history: []
          },
          messages: [],
          events: []
        }
      end
    end

    def snapshot(thread_id)
      state = state_for(thread_id)
      context = state[:context]

      {
        thread_id: thread_id,
        current_agent: context[:current_agent] || @agents[:triage].name,
        context: Airline.public_context(context[:state]),
        agents: agents_list,
        events: state[:events].map(&:to_h),
        messages: state[:messages],
        show_seat_map: context[:state][:show_seat_map] == true
      }
    end

    def agents_list
      @agents.values.map do |agent|
        {
          name: agent.name,
          description: agent_description(agent.name),
          handoffs: agent.handoff_agents.map(&:name),
          tools: agent.tools.map(&:name),
          input_guardrails: []
        }
      end
    end

    def agent_description(name)
      {
        "Triage Agent" => "Delegates requests to the right specialist agent.",
        "FAQ Agent" => "Answers common airline policy questions.",
        "Seat and Special Services Agent" => "Updates seats and handles special service seating.",
        "Flight Information Agent" => "Provides flight status, connection risk, and alternate options.",
        "Booking and Cancellation Agent" => "Handles bookings, rebookings, and cancellations.",
        "Refunds and Compensation Agent" => "Opens compensation cases and issues support after delays."
      }[name] || ""
    end

    def record_context_update(thread_id, before_context, after_context)
      changes = after_context.each_with_object({}) do |(key, value), memo|
        memo[key] = value if before_context[key] != value
      end
      return if changes.empty?

      record_event(thread_id, "context_update", "Context", "Context updated", changes: changes)
    end

    def record_event(thread_id, type, agent, content, metadata = {})
      return unless thread_id

      event = Event.new(
        id: SecureRandom.hex(8),
        type: type,
        agent: agent,
        content: content.to_s,
        metadata: metadata,
        timestamp: now_ms
      )

      @mutex.synchronize do
        @states[thread_id] ||= {
          context: {
            thread_id: thread_id,
            state: Airline.initial_state,
            current_agent: @agents[:triage].name,
            conversation_history: []
          },
          messages: [],
          events: []
        }
        @states[thread_id][:events] << event
        @states[thread_id][:events] = @states[thread_id][:events].last(120)
      end
    end

    def normalize_output(output)
      case output
      when Hash
        output["response"] || output[:response] || JSON.generate(output)
      when Array
        output.join("\n")
      when nil
        "[No response]"
      else
        output.to_s
      end
    end

    def safe_error_message(error)
      message = error.message.to_s
      return "The OpenAI API key was rejected. Set a valid OPENAI_API_KEY and retry." if message.match?(/api key/i)

      "I could not complete that request: #{message}"
    end

    def now_ms
      (Time.now.to_f * 1000).round
    end
  end

  class Server
    MIME_TYPES = {
      ".html" => "text/html",
      ".css" => "text/css",
      ".js" => "application/javascript",
      ".svg" => "image/svg+xml",
      ".jpg" => "image/jpeg",
      ".png" => "image/png"
    }.freeze

    def initialize(port: ENV.fetch("PORT", "4567").to_i)
      @app = App.new
      @public_root = File.expand_path("public", __dir__)
      @server = WEBrick::HTTPServer.new(
        Port: port,
        BindAddress: "127.0.0.1",
        AccessLog: [],
        Logger: WEBrick::Log.new($stderr, WEBrick::Log::INFO)
      )
      mount_routes
    end

    def start
      trap("INT") { @server.shutdown }
      puts "Customer service agents demo running at http://127.0.0.1:#{@server.config[:Port]}"
      @server.start
    end

    private

    def mount_routes
      @server.mount_proc("/api/bootstrap") { |_req, res| json(res, @app.bootstrap) }
      @server.mount_proc("/api/state") { |req, res| json(res, @app.state(req.query["thread_id"])) }
      @server.mount_proc("/api/reset") { |req, res| json(res, @app.reset(parsed_body(req)["thread_id"])) }
      @server.mount_proc("/api/message") do |req, res|
        body = parsed_body(req)
        json(res, @app.message(body["thread_id"], body["message"]))
      end
      @server.mount_proc("/api/seat") do |req, res|
        body = parsed_body(req)
        json(res, @app.choose_seat(body["thread_id"], body["seat"]))
      end
      @server.mount_proc("/") { |req, res| static(req, res) }
    end

    def parsed_body(req)
      return {} if req.body.nil? || req.body.empty?

      JSON.parse(req.body)
    rescue JSON::ParserError
      {}
    end

    def json(res, payload, status: 200)
      res.status = status
      res["Content-Type"] = "application/json"
      res.body = JSON.generate(payload)
    end

    def static(req, res)
      relative_path = req.path == "/" ? "index.html" : req.path.sub(%r{\A/}, "")
      path = File.expand_path(relative_path, @public_root)
      unless path.start_with?(@public_root) && File.file?(path)
        res.status = 404
        res.body = "Not found"
        return
      end

      res["Content-Type"] = MIME_TYPES.fetch(File.extname(path), "application/octet-stream")
      res.body = File.binread(path)
    end
  end
end

CSDemo::Server.new.start if $PROGRAM_NAME == __FILE__
