# frozen_string_literal: true

module Agents
  # Service object responsible for extracting and formatting conversation messages
  # from RubyLLM chat objects into a format suitable for persistence and context restoration.
  #
  # Handles different message types:
  # - User messages: Basic content preservation
  # - Assistant messages: Includes agent attribution and tool calls
  # - Tool result messages: Links back to original tool calls
  #
  # @example Extract messages from a chat
  #   messages = MessageExtractor.extract_messages(chat, current_agent)
  #   #=> [
  #     { role: :user, content: "Hello" },
  #     { role: :assistant, content: "Hi!", agent_name: "Support", tool_calls: [...] },
  #     { role: :tool, content: "Result", tool_call_id: "call_123" }
  #   ]
  class MessageExtractor
    # Extract messages from a chat object for conversation history persistence
    #
    # @param chat [Object] Chat object that responds to :messages
    # @param current_agent [Agent] The agent currently handling the conversation
    # @return [Array<Hash>] Array of message hashes suitable for persistence
    def self.extract_messages(chat, current_agent)
      new(chat, current_agent).extract
    end

    private

    def initialize(chat, current_agent)
      @chat = chat
      @current_agent = current_agent
    end

    def extract
      return [] unless @chat.respond_to?(:messages)

      @chat.messages.filter_map do |msg|
        case msg.role
        when :user, :assistant
          extract_user_or_assistant_message(msg)
        when :tool
          extract_tool_message(msg)
        end
      end
    end

    def extract_user_or_assistant_message(msg)
      return nil unless msg.content && !msg.content.strip.empty?

      message = {
        role: msg.role,
        content: msg.content
      }

      if msg.role == :assistant
        # Add agent attribution for conversation continuity
        message[:agent_name] = @current_agent.name if @current_agent

        # Add tool calls if present
        message[:tool_calls] = msg.tool_calls.map(&:to_h) if msg.tool_call?
      end

      message
    end

    def extract_tool_message(msg)
      return nil unless msg.tool_result?

      {
        role: msg.role,
        content: msg.content,
        tool_call_id: msg.tool_call_id
      }
    end
  end
end
