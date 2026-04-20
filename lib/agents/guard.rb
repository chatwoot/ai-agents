# frozen_string_literal: true

# Guard is the base class for all guardrails, providing a stateless interface for
# validating and transforming input/output content before and after agent execution.
#
# ## Thread-Safe Design
# Guards follow the same thread-safety principles as Tools:
# 1. No execution state in instance variables - only configuration
# 2. All state passed through parameters - RunContext provides shared state
# 3. Immutable guard instances - create once, use everywhere
# 4. Stateless call methods - pure functions with context input
#
# ## Guard Actions
# A guard's `call` method returns nil (pass) or a GuardResult:
# - **pass**: Content is acceptable, continue execution
# - **rewrite**: Replace the content with a modified version
# - **tripwire**: Abort the run immediately with an error
#
# @example Detecting prompt injection
#   class PromptInjectionGuard < Agents::Guard
#     guard_name "prompt_injection_detector"
#     description "Detects common prompt injection patterns"
#
#     def call(content, context)
#       return if content.nil?
#
#       if content.match?(/ignore\s+(all\s+)?previous\s+instructions/i)
#         GuardResult.tripwire(message: "Potential prompt injection detected")
#       end
#     end
#   end
#
# @example Redacting PII from output
#   class PiiRedactor < Agents::Guard
#     guard_name "pii_redactor"
#     description "Redacts SSNs from output"
#
#     def call(content, context)
#       return if content.nil?
#       redacted = content.gsub(/\b\d{3}-\d{2}-\d{4}\b/, "[REDACTED]")
#       GuardResult.rewrite(redacted, message: "PII redacted") if redacted != content
#     end
#   end
module Agents
  # Base class for all guardrails. See top-of-file comment for design details.
  class Guard
    # Exception raised when a guard tripwires, aborting the run.
    class Tripwire < StandardError
      attr_reader :guard_name, :metadata

      def initialize(message, guard_name:, metadata: {})
        @guard_name = guard_name
        @metadata = metadata
        super(message)
      end
    end

    # Evaluate content against this guard.
    # Subclasses must implement this method.
    #
    # @param content [String] The input or output text being validated
    # @param context [Agents::RunContext] The current execution context
    # @return [GuardResult, nil] nil means pass; GuardResult for rewrite/tripwire
    def call(content, context)
      raise NotImplementedError, "Guards must implement #call(content, context)"
    end

    # DSL method to set or get the guard's name.
    # Defaults to the class name's last segment if not explicitly set.
    #
    # @param value [String, nil] The guard name to set, or nil to get
    # @return [String] The guard's name
    def self.guard_name(value = nil)
      if value
        @guard_name = value
      else
        @guard_name || name&.split("::")&.last
      end
    end

    # DSL method to set or get the guard's description.
    #
    # @param value [String, nil] The description to set, or nil to get
    # @return [String, nil] The guard's description
    def self.description(value = nil)
      if value
        @description = value
      else
        @description
      end
    end

    # Instance-level name accessor, delegates to class method.
    def name
      self.class.guard_name
    end
  end
end
