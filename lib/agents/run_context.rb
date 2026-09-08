# frozen_string_literal: true

module Agents
  # Application state and accounting for one execution, never stored on an agent.
  class RunContext
    attr_reader :context, :usage, :callbacks, :callback_manager

    def initialize(context, callbacks: {})
      @context = context
      @usage = Usage.new
      @callbacks = callbacks || {}
      @callback_manager = CallbackManager.new(@callbacks)
    end

    class Usage
      attr_reader :entries

      def initialize
        @entries = []
      end

      def record(payload)
        @entries << payload.slice(:operation, :provider, :model, :status, :tokens, :cost)
      end

      def add(response)
        record(tokens: response.tokens, cost: response.cost)
      end

      def merge(other)
        @entries.concat(other.entries)
      end

      # Let RubyLLM preserve unknown token buckets and price provider attempts.
      # https://rubyllm.com/next/cost-and-usage-tracking/
      def tokens
        RubyLLM::Tokens.aggregate(entries.map { |entry| entry[:tokens] })
      end

      def cost
        costs = entries.map { |entry| entry[:cost] }
        RubyLLM::Cost.aggregate(costs, complete: costs.all? { |cost| cost && !cost.total.nil? })
      end

      # Compatibility readers. Native tokens keep unknown counts as nil.
      def input_tokens = tokens.input || 0
      def output_tokens = tokens.output || 0
      def total_tokens = input_tokens + output_tokens
    end
  end
end
