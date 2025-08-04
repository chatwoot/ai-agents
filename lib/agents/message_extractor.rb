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
    # Check if content is considered empty (handles both String and Hash content)
    #
    # @param content [String, Hash, nil] The content to check
    # @return [Boolean] true if content is empty, false otherwise
    def self.content_empty?(content)
      case content
      when String
        content.strip.empty?
      when Hash
        content.empty?
      else
        content.nil?
      end
    end

    # Extract messages from a chat object for conversation history persistence
    #
    # @param chat [Object] Chat object that responds to :messages
    # @param current_agent [Agent] The agent currently handling the conversation
    # @return [Array<Hash>] Array of message hashes suitable for persistence
    def self.extract_messages(chat, current_agent)
      new(chat, current_agent).extract
    end

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

    private

    def extract_user_or_assistant_message(msg)
      return nil unless msg.content && !self.class.content_empty?(msg.content)

      message = {
        role: msg.role,
        content: msg.content
      }

      if msg.role == :assistant
        # Add agent attribution for conversation continuity
        message[:agent_name] = @current_agent.name if @current_agent

        # Add tool calls if present
        if msg.tool_call? && msg.tool_calls
          # RubyLLM stores tool_calls as Hash with call_id => ToolCall object
          # Reference: RubyLLM::StreamAccumulator#tool_calls_from_stream
          message[:tool_calls] = msg.tool_calls.values.map(&:to_h)
        end
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
