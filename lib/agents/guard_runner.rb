# frozen_string_literal: true

module Agents
  # Executes an ordered chain of guards against content.
  # Guards run in array order, each seeing the (potentially rewritten) output of the previous guard.
  # A tripwire short-circuits the chain immediately.
  #
  # ## Structured Output
  # When content is a Hash or Array (e.g. from response_schema), it is serialized to JSON
  # before the guard chain so guards always receive a String. If any guard rewrites, the
  # final result deserializes back to the original type. Access `result.output` to get
  # the type-preserved value.
  #
  # ## Fail-Open vs Fail-Closed
  # By default, if a guard raises an unexpected exception, it is logged and treated as a pass
  # (fail-open). With `strict: true`, unexpected exceptions become tripwires (fail-closed).
  #
  # @example Running guards
  #   result = GuardRunner.run(
  #     [PiiRedactor.new, TopicFence.new],
  #     "Some content with 123-45-6789",
  #     context_wrapper,
  #     phase: :output
  #   )
  #   result.content # => "Some content with [REDACTED]"
  class GuardRunner
    # Run a chain of guards against content.
    #
    # @param guards [Array<Guard>] Ordered list of guards to execute
    # @param content [String, Hash, Array, nil] The content to validate
    # @param context [RunContext] Execution context
    # @param phase [Symbol] :input or :output (used in callbacks/instrumentation)
    # @param strict [Boolean] If true, guard exceptions become tripwires instead of being swallowed
    # @return [GuardResult] Final result after all guards run (content may have been rewritten)
    # @raise [Guard::Tripwire] If any guard tripwires
    def self.run(guards, content, context, phase:, strict: false)
      return GuardResult.new(action: :pass, content: content) if guards.empty? || content.nil?

      # Serialize structured content so guards always receive a String
      structured = content.is_a?(Hash) || content.is_a?(Array)
      current_content = structured ? content.to_json : content
      any_rewrite = false

      guards.each do |guard|
        result = safe_execute(guard, current_content, context, strict: strict)
        next if result.nil? || result.pass?

        any_rewrite = true if result.rewrite?
        current_content = apply_result(result, guard, phase, context)
      end

      action = any_rewrite ? :rewrite : :pass
      output = resolve_output(any_rewrite, structured, current_content, content)
      GuardResult.new(action: action, content: current_content, output: output)
    end

    # Resolves the final output value after the guard chain completes.
    # Handles structured content deserialization back to Hash/Array when guards rewrote it.
    def self.resolve_output(any_rewrite, structured, current_content, original_content)
      return original_content unless any_rewrite
      return current_content unless structured

      JSON.parse(current_content)
    rescue JSON::ParserError => e
      raise JSON::ParserError,
            "Guard chain produced invalid JSON for structured output: #{e.message}"
    end

    # Emits a callback and applies the guard result (rewrite or tripwire).
    # @return [String] The (possibly rewritten) content
    # @raise [Guard::Tripwire] If the result is a tripwire
    def self.apply_result(result, guard, phase, context)
      context.callback_manager.emit_guard_triggered(
        guard.name, phase, result.action, result.message, context
      )

      if result.tripwire?
        raise Guard::Tripwire.new(
          result.message,
          guard_name: guard.name,
          metadata: result.metadata
        )
      end

      result.content
    end

    # Execute a single guard with error handling.
    #
    # @param guard [Guard] The guard to execute
    # @param content [String] Content to validate
    # @param context [RunContext] Execution context
    # @param strict [Boolean] Whether to fail-closed on errors
    # @return [GuardResult, nil] The guard's result, or nil on swallowed errors
    # @raise [Guard::Tripwire] On tripwires (always) or on errors in strict mode
    def self.safe_execute(guard, content, context, strict: false)
      result = guard.call(content, context)
      return result if result.nil? || result.is_a?(GuardResult)

      raise TypeError, "Guard #{guard.name} must return nil or GuardResult, got #{result.class}"
    rescue Guard::Tripwire
      raise # Always re-raise tripwires
    rescue StandardError => e
      if strict
        raise Guard::Tripwire.new(
          "Guard #{guard.name} failed: #{e.message}",
          guard_name: guard.name,
          metadata: { original_error: e.class.name }
        )
      end
      Agents.logger&.warn("Guard #{guard.name} error (non-strict, passing): #{e.message}")
      nil # Fail open
    end
  end
end
