# frozen_string_literal: true

module Agents
  RunResult = Struct.new(:output, :messages, :usage, :error, :context, :chat, :request_options, keyword_init: true) do
    def success?
      error.nil? && !output.nil?
    end

    def failed?
      !success?
    end

    def awaiting_approval?
      !!chat&.awaiting_approval?
    end
  end
end
