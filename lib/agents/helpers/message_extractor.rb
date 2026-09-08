# frozen_string_literal: true

module Agents
  module Helpers
    # RubyLLM owns the wire format; we only add agent attribution.
    module MessageExtractor
      AUTHORING_AGENT_IVAR = :@agents_authoring_agent

      module_function

      def assign_agent_name(message, agent_name)
        message.instance_variable_set(AUTHORING_AGENT_IVAR, agent_name) if message && agent_name
      end

      def attributed_agent_name_for(message)
        message&.instance_variable_get(AUTHORING_AGENT_IVAR)
      end

      # Native serialization retains reasoning signatures, citations, and attachments.
      # https://github.com/crmne/ruby_llm/blob/v2.0.0.rc1/lib/ruby_llm/message.rb
      def extract_messages(chat, current_agent)
        return [] unless chat.respond_to?(:messages)

        chat.messages.filter_map do |message|
          next if message.role == :system

          attributes = message.to_h
          if message.role == :assistant
            author = attributed_agent_name_for(message) || current_agent&.name
            attributes[:agent_name] = author if author
          end
          attributes
        end
      end

      # Accept the old SDK history shape at the boundary, then let RubyLLM coerce
      # its own fields. Do not symbolize nested payloads or tool-call IDs.
      def restore_message(attributes)
        attributes = attributes.transform_keys(&:to_sym)
        author = attributes.delete(:agent_name)
        content = attributes[:content]
        attributes[:content] = content.to_json if content.is_a?(Hash)
        attributes.merge!(legacy_content(content)) if content.is_a?(Array)

        if attributes[:tool_calls].is_a?(Array)
          attributes[:tool_calls] = attributes[:tool_calls].filter_map do |call|
            call = call.transform_keys(&:to_sym)
            [call[:id], call] if call[:id]
          end.to_h
        end

        # rc1 serializes attachment sources but does not rehydrate those hashes.
        attributes[:attachments] = attributes[:attachments]&.map do |attachment|
          attachment.is_a?(Hash) ? attachment[:source] || attachment["source"] : attachment
        end

        message = RubyLLM::Message.new({ content: nil }.merge(attributes))
        assign_agent_name(message, author)
        message
      end

      def legacy_content(content)
        parts = content.map { |part| part.transform_keys(&:to_sym) }
        {
          content: parts.filter_map { |part| part[:text] if part[:type] == "text" }.join(" "),
          attachments: parts.filter_map do |part|
            image = part[:image_url]
            image[:url] || image["url"] if part[:type] == "image_url" && image
          end
        }
      end
      private_class_method :legacy_content
    end
  end
end
