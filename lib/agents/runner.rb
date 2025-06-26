# frozen_string_literal: true

module Agents
  # The execution engine that orchestrates conversations between users and agents.
  # Runner manages the conversation flow, handles tool execution through RubyLLM,
  # coordinates handoffs between agents, and ensures thread-safe operation.
  #
  # The Runner follows a turn-based execution model where each turn consists of:
  # 1. Sending a message to the LLM with current context
  # 2. Receiving a response that may include tool calls
  # 3. Executing tools and getting results (handled by RubyLLM)
  # 4. Checking for agent handoffs
  # 5. Continuing until no more tools are called
  #
  # ## Thread Safety
  # The Runner ensures thread safety by:
  # - Creating new context wrappers for each execution
  # - Using tool wrappers that pass context through parameters
  # - Never storing execution state in shared variables
  #
  # ## Integration with RubyLLM
  # We leverage RubyLLM for LLM communication and tool execution while
  # maintaining our own context management and handoff logic.
  #
  # @example Simple conversation
  #   agent = Agents::Agent.new(
  #     name: "Assistant",
  #     instructions: "You are a helpful assistant",
  #     tools: [weather_tool]
  #   )
  #
  #   result = Agents::Runner.run(agent, "What's the weather?")
  #   puts result.output
  #   # => "Let me check the weather for you..."
  #
  # @example Conversation with context
  #   result = Agents::Runner.run(
  #     support_agent,
  #     "I need help with my order",
  #     context: { user_id: 123, order_id: 456 }
  #   )
  #
  # @example Multi-agent handoff
  #   triage = Agents::Agent.new(
  #     name: "Triage",
  #     instructions: "Route users to the right specialist",
  #     handoff_agents: [billing_agent, tech_agent]
  #   )
  #
  #   result = Agents::Runner.run(triage, "I can't pay my bill")
  #   # Triage agent will handoff to billing_agent
  class Runner
    DEFAULT_MAX_TURNS = 10

    class MaxTurnsExceeded < StandardError; end

    # Convenience class method for running agents
    def self.run(agent, input, context: {}, max_turns: DEFAULT_MAX_TURNS)
      new.run(agent, input, context: context, max_turns: max_turns)
    end

    # Execute an agent with the given input and context
    #
    # @param starting_agent [Agents::Agent] The initial agent to run
    # @param input [String] The user's input message
    # @param context [Hash] Shared context data accessible to all tools
    # @param max_turns [Integer] Maximum conversation turns before stopping
    # @return [RunResult] The result containing output, messages, and usage
    def run(starting_agent, input, context: {}, max_turns: DEFAULT_MAX_TURNS)
      Tracing.in_span("conversation.#{starting_agent.service_name}", kind: :server, 
                      "agent.name" => starting_agent.name,
                      "agent.class" => starting_agent.class.name,
                      "agent.instructions_length" => starting_agent.get_system_prompt(nil)&.length || 0,
                      "agent.tools_count" => starting_agent.all_tools.length,
                      "agent.tool_names" => starting_agent.all_tools.map(&:name).join(","),
                      "agent.handoff_agents_count" => starting_agent.handoff_agents.length,
                      "agent.handoff_agent_names" => starting_agent.handoff_agents.map(&:name).join(","),
                      "conversation.input" => Agents.configuration.tracing.include_sensitive_data ? input : "[REDACTED]",
                      "conversation.input_length" => input.length,
                      "conversation.max_turns" => max_turns,
                      "conversation.has_context" => !context.empty?,
                      "conversation.context_keys" => context.keys.join(","),
                      "conversation.resume" => !context[:current_agent].nil?) do |span|
        
        # Determine current agent from context or use starting agent
        current_agent = context[:current_agent] || starting_agent

        # Create context wrapper with deep copy for thread safety
        context_copy = deep_copy_context(context)
        context_wrapper = RunContext.new(context_copy)
        current_turn = 0

        span.add_event("conversation.initialized", attributes: {
          "context.size" => context_copy.keys.length,
          "conversation_history.length" => (context_copy[:conversation_history] || []).length,
          "agent.switched" => current_agent != starting_agent
        })

        # Create chat and restore conversation history
        chat = Tracing.in_span("chat.initialize", kind: :internal,
                               "chat.agent_name" => current_agent.name,
                               "chat.model" => current_agent.model,
                               "chat.provider" => determine_provider(current_agent.model)) do |chat_span|
          chat_instance = create_chat(current_agent, context_wrapper)
          
          # Restore conversation history with tracing
          history_length = restore_conversation_history(chat_instance, context_wrapper)
          chat_span.set_attribute("chat.restored_messages", history_length)
          
          chat_instance
        end

        loop do
          current_turn += 1
          raise MaxTurnsExceeded, "Exceeded maximum turns: #{max_turns}" if current_turn > max_turns

          span.set_attribute("conversation.turn", current_turn)
          span.set_attribute("conversation.current_agent", current_agent.name)
          span.add_event("conversation.turn_started", attributes: {
            "turn.number" => current_turn,
            "turn.agent" => current_agent.name,
            "turn.is_first" => current_turn == 1
          })

          # Get response from LLM (RubyLLM handles tool execution)
          response = Tracing.in_span("llm.#{current_agent.model}", kind: :client,
                                     "llm.model" => current_agent.model,
                                     "llm.provider" => determine_provider(current_agent.model),
                                     "llm.turn" => current_turn,
                                     "llm.is_first_turn" => current_turn == 1,
                                     "llm.available_tools" => current_agent.all_tools.map(&:name).join(","),
                                     "llm.available_tools_count" => current_agent.all_tools.length) do |llm_span|
            
            llm_span.add_event("llm.request_started", attributes: {
              "request.type" => current_turn == 1 ? "ask" : "complete",
              "request.input" => current_turn == 1 ? (Agents.configuration.tracing.include_sensitive_data ? input : "[REDACTED]") : "[CONTINUATION]"
            })
            
            start_time = Time.now
            result = if current_turn == 1
                       chat.ask(input)
                     else
                       chat.complete
                     end
            duration = Time.now - start_time
            
            # Add comprehensive response attributes to span
            llm_span.set_attribute("llm.response_time_ms", (duration * 1000).round(2))
            llm_span.set_attribute("llm.response_has_content", !result.content.to_s.empty?)
            llm_span.set_attribute("llm.response_content_length", result.content.to_s.length)
            llm_span.set_attribute("llm.has_tool_calls", result.tool_call?)
            
            if result.respond_to?(:usage) && result.usage
              llm_span.set_attribute("llm.input_tokens", result.usage.input_tokens)
              llm_span.set_attribute("llm.output_tokens", result.usage.output_tokens)
              llm_span.set_attribute("llm.total_tokens", result.usage.total_tokens)
              llm_span.set_attribute("llm.cost_estimate", estimate_cost(result.usage, current_agent.model))
            end
            
            # Add tool call information if present
            if result.tool_call?
              # RubyLLM handles tool execution, but we can detect it happened
              llm_span.add_event("llm.tool_calls_detected", attributes: {
                "tools.will_execute" => true,
                "tools.available_count" => current_agent.all_tools.length
              })
            end
            
            if Agents.configuration.tracing.include_sensitive_data && result.content.to_s.length < 1000
              llm_span.set_attribute("llm.response_content", result.content.to_s)
            end
            
            result
          end

          # Update usage
          context_wrapper.usage.add(response.usage) if response.respond_to?(:usage) && response.usage

          # Check for handoff via context (set by HandoffTool)
          if context_wrapper.context[:pending_handoff]
            next_agent = context_wrapper.context[:pending_handoff]
            puts "[Agents] Handoff from #{current_agent.name} to #{next_agent.name}"

            Tracing.in_span("handoff.#{current_agent.name}_to_#{next_agent.name}", kind: :internal,
                            "handoff.from_agent" => current_agent.name,
                            "handoff.from_agent_class" => current_agent.class.name,
                            "handoff.to_agent" => next_agent.name,
                            "handoff.to_agent_class" => next_agent.class.name,
                            "handoff.turn" => current_turn,
                            "handoff.reason" => context_wrapper.context[:handoff_reason] || "unknown",
                            "handoff.triggered_by" => "tool_call") do |handoff_span|
              
              handoff_span.add_event("handoff.started", attributes: {
                "previous_agent.tools_count" => current_agent.all_tools.length,
                "next_agent.tools_count" => next_agent.all_tools.length,
                "conversation.history_length" => (context_wrapper.context[:conversation_history] || []).length
              })
              
              # Save current conversation state before switching
              save_conversation_state(chat, context_wrapper, current_agent)
              handoff_span.add_event("handoff.state_saved")

              # Switch to new agent
              current_agent = next_agent
              context_wrapper.context[:current_agent] = next_agent
              context_wrapper.context.delete(:pending_handoff)
              context_wrapper.context.delete(:handoff_reason)

              # Create new chat for new agent with restored history
              chat = create_chat(current_agent, context_wrapper)
              history_length = restore_conversation_history(chat, context_wrapper)
              
              handoff_span.set_attribute("handoff.new_agent_history_length", history_length)
              handoff_span.add_event("handoff.completed", attributes: {
                "new_agent.name" => current_agent.name,
                "new_agent.tools" => current_agent.all_tools.map(&:name).join(",")
              })
            end
            next
          end

          # If no tools were called, we have our final response
          next if response.tool_call?

          # Save final state before returning
          save_conversation_state(chat, context_wrapper, current_agent)

          span.set_attribute("conversation.final_agent", current_agent.name)
          span.set_attribute("conversation.total_turns", current_turn)
          span.set_attribute("conversation.total_tokens_used", context_wrapper.usage.total_tokens)
          span.set_attribute("conversation.output_length", response.content.to_s.length)
          span.set_attribute("conversation.status", "completed")
          
          span.add_event("conversation.completed", attributes: {
            "final.agent" => current_agent.name,
            "final.turns" => current_turn,
            "final.output_length" => response.content.to_s.length,
            "final.total_tokens" => context_wrapper.usage.total_tokens,
            "final.message_count" => extract_messages(chat).length
          })
          
          return RunResult.new(
            output: response.content,
            messages: extract_messages(chat),
            usage: context_wrapper.usage,
            context: context_wrapper.context
          )
        end
      rescue MaxTurnsExceeded => e
        # Save state even on error
        save_conversation_state(chat, context_wrapper, current_agent) if chat

        span.set_attribute("conversation.error", "max_turns_exceeded")
        span.set_attribute("conversation.error_message", e.message)
        span.set_attribute("conversation.status", "failed")
        span.set_attribute("conversation.failure_reason", "max_turns_exceeded")
        span.set_attribute("conversation.turns_at_failure", current_turn)
        
        span.add_event("conversation.failed", attributes: {
          "error.type" => "MaxTurnsExceeded",
          "error.message" => e.message,
          "error.turns_completed" => current_turn,
          "error.max_turns" => max_turns
        })
        
        RunResult.new(
          output: "Conversation ended: #{e.message}",
          messages: chat ? extract_messages(chat) : [],
          usage: context_wrapper&.usage,
          error: e,
          context: context_wrapper&.context
        )
      rescue StandardError => e
        # Save state even on error
        save_conversation_state(chat, context_wrapper, current_agent) if chat

        span.set_attribute("conversation.error", e.class.name)
        span.set_attribute("conversation.error_message", e.message)
        span.set_attribute("conversation.status", "failed")
        span.set_attribute("conversation.failure_reason", "runtime_error")
        span.set_attribute("conversation.turns_at_failure", current_turn || 0)
        
        span.add_event("conversation.failed", attributes: {
          "error.type" => e.class.name,
          "error.message" => e.message,
          "error.stacktrace" => e.backtrace&.first(5)&.join("\n") || "unknown"
        })
        
        RunResult.new(
          output: nil,
          messages: chat ? extract_messages(chat) : [],
          usage: context_wrapper&.usage,
          error: e,
          context: context_wrapper&.context
        )
      end
    end

    private

    def deep_copy_context(context)
      # Handle deep copying for thread safety
      context.dup.tap do |copied|
        copied[:conversation_history] = context[:conversation_history]&.map(&:dup) || []
        # Don't copy agents - they're immutable
        copied[:current_agent] = context[:current_agent]
        copied[:turn_count] = context[:turn_count] || 0
      end
    end

    def restore_conversation_history(chat, context_wrapper)
      history = context_wrapper.context[:conversation_history] || []
      restored_count = 0

      history.each do |msg|
        # Only restore user and assistant messages with content
        next unless %i[user assistant].include?(msg[:role])
        next unless msg[:content] && !msg[:content].strip.empty?

        chat.add_message(
          role: msg[:role].to_sym,
          content: msg[:content]
        )
        restored_count += 1
      rescue StandardError => e
        # Continue with partial history on error
        puts "[Agents] Failed to restore message: #{e.message}"
      end
      
      restored_count
    rescue StandardError => e
      # If history restoration completely fails, continue with empty history
      puts "[Agents] Failed to restore conversation history: #{e.message}"
      context_wrapper.context[:conversation_history] = []
      0
    end

    def save_conversation_state(chat, context_wrapper, current_agent)
      # Extract messages from chat
      messages = extract_messages(chat)

      # Update context with latest state
      context_wrapper.context[:conversation_history] = messages
      context_wrapper.context[:current_agent] = current_agent
      context_wrapper.context[:turn_count] = (context_wrapper.context[:turn_count] || 0) + 1
      context_wrapper.context[:last_updated] = Time.now

      # Clean up temporary handoff state
      context_wrapper.context.delete(:pending_handoff)
    rescue StandardError => e
      puts "[Agents] Failed to save conversation state: #{e.message}"
    end

    def create_chat(agent, context_wrapper)
      # Get system prompt (may be dynamic)
      system_prompt = agent.get_system_prompt(context_wrapper)

      # Wrap tools with context for thread-safe execution
      wrapped_tools = agent.all_tools.map do |tool|
        ToolWrapper.new(tool, context_wrapper)
      end

      # Create chat with proper RubyLLM API
      chat = RubyLLM.chat(model: agent.model)
      chat.with_instructions(system_prompt) if system_prompt
      chat.with_tools(*wrapped_tools) if wrapped_tools.any?
      chat
    end

    # Estimate cost based on usage and model
    def estimate_cost(usage, model)
      return 0.0 unless usage.respond_to?(:input_tokens) && usage.respond_to?(:output_tokens)
      
      # Simple cost estimation - would need real pricing data
      case model.to_s.downcase
      when /gpt-4o/
        input_cost = usage.input_tokens * 0.005 / 1000
        output_cost = usage.output_tokens * 0.015 / 1000
        input_cost + output_cost
      when /gpt-4/
        input_cost = usage.input_tokens * 0.03 / 1000
        output_cost = usage.output_tokens * 0.06 / 1000
        input_cost + output_cost
      when /gpt-3.5/
        input_cost = usage.input_tokens * 0.001 / 1000
        output_cost = usage.output_tokens * 0.002 / 1000
        input_cost + output_cost
      else
        0.0
      end.round(4)
    end

    # Determine provider from model name
    def determine_provider(model)
      case model.to_s.downcase
      when /gpt/, /openai/ then "openai"
      when /claude/, /anthropic/ then "anthropic"
      when /gemini/, /google/ then "google"
      else "unknown"
      end
    end

    def extract_messages(chat)
      return [] unless chat.respond_to?(:messages)

      chat.messages.filter_map do |msg|
        # Only include user and assistant messages with content
        next unless %i[user assistant].include?(msg.role)
        next unless msg.content && !msg.content.strip.empty?

        {
          role: msg.role,
          content: msg.content
        }
      end
    end
  end
end
