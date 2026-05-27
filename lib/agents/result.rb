# frozen_string_literal: true

module Agents
  RunResult = Struct.new(:output, :messages, :usage, :error, :context, :guardrail_tripwire, keyword_init: true) do
    def success?
      error.nil? && !output.nil?
    end

    def failed?
      !success?
    end

    def tripwired?
      !guardrail_tripwire.nil?
    end
  end
end
