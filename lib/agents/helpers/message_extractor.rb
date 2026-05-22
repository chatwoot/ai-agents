# frozen_string_literal: true

# Service object responsible for extracting and formatting conversation messages
# from RubyLLM chat objects into a format suitable for persistence and context restoration.
#
# Handles different message types:
# - User messages: Basic content preservation
# - Assistant messages: Includes agent attribution and tool calls
# - Tool result messages: Links back to original tool calls
#
# @example Extract messages from a chat
#   messages = Agents::Helpers::MessageExtractor.extract_messages(chat, current_agent)
#   #=> [
#     { role: :user, content: "Hello" },
#     { role: :assistant, content: "Hi!", agent_name: "Support", tool_calls: [...] },
#     { role: :tool, content: "Result", tool_call_id: "call_123" }
#   ]
module Agents
  module Helpers
    module MessageExtractor
      # RubyLLM::Message has no metadata/extension API, so agent ownership is stored
      # as an SDK-namespaced ivar on the message object until it is extracted.
      AUTHORING_AGENT_IVAR = :@agents_authoring_agent

      module_function

      def assign_agent_name(message, agent_name)
        return unless message && agent_name

        message.instance_variable_set(AUTHORING_AGENT_IVAR, agent_name)
      end

      def attributed_agent_name_for(message)
        return unless message&.instance_variable_defined?(AUTHORING_AGENT_IVAR)

        message.instance_variable_get(AUTHORING_AGENT_IVAR)
      end

      # Check if content is considered empty (handles both String and Hash content)
      #
      # @param content [String, Hash, nil] The content to check
      # @return [Boolean] true if content is empty, false otherwise
      def content_empty?(content)
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
      def extract_messages(chat, current_agent)
        return [] unless chat.respond_to?(:messages)

        chat.messages.filter_map do |msg|
          case msg.role
          when :user, :assistant
            extract_user_or_assistant_message(msg, current_agent)
          when :tool
            extract_tool_message(msg)
          end
        end
      end

      def extract_user_or_assistant_message(msg, current_agent)
        content_present = message_content?(msg)
        tool_calls_present = assistant_tool_calls?(msg)
        return nil unless content_present || tool_calls_present

        message = {
          role: msg.role,
          content: content_present ? msg.content : ""
        }

        return message unless msg.role == :assistant

        attributed_agent_name = attributed_agent_name_for(msg) || current_agent&.name
        message[:agent_name] = attributed_agent_name if attributed_agent_name

        if tool_calls_present
          # RubyLLM stores tool_calls as Hash with call_id => ToolCall object
          # Reference: RubyLLM::StreamAccumulator#tool_calls_from_stream
          message[:tool_calls] = msg.tool_calls.values.map(&:to_h)
        end

        message
      end

      def message_content?(msg)
        msg.content && !content_empty?(msg.content)
      end

      def assistant_tool_calls?(msg)
        msg.role == :assistant && msg.tool_call? && msg.tool_calls && !msg.tool_calls.empty?
      end

      def extract_tool_message(msg)
        return nil unless msg.tool_result?

        {
          role: msg.role,
          content: msg.content,
          tool_call_id: msg.tool_call_id
        }
      end

      private_class_method :extract_user_or_assistant_message, :message_content?, :assistant_tool_calls?,
                           :extract_tool_message
    end
  end
end
