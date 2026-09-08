# frozen_string_literal: true

require "base64"
require "stringio"

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
          if message.attachments.any?
            attributes[:attachments] = message.attachments.map do |attachment|
              next attachment.to_h unless attachment.source.respond_to?(:read)

              { type: attachment.type, filename: attachment.filename,
                source: "data:#{attachment.mime_type};base64,#{Base64.strict_encode64(attachment.content)}" }
            end
          end
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
          restore_attachment(attachment)
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

      # V2 accepts IO attachments, not legacy data URLs. Keep inline bytes durable
      # when a restored image is saved again, rather than serializing an IO object.
      def restore_attachment(attachment)
        attributes = attachment.is_a?(Hash) ? attachment.transform_keys(&:to_sym) : { source: attachment }
        source = attributes[:source]
        match = source.match(/\Adata:([^;,]+);base64,(.*)\z/m) if source.is_a?(String)
        return source unless match

        filename = attributes[:filename] || "attachment.#{match[1].split("/").last.split("+").first}"
        RubyLLM::Attachment.new(StringIO.new(Base64.strict_decode64(match[2])), filename: filename)
      end
      private_class_method :legacy_content, :restore_attachment
    end
  end
end
