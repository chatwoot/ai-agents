# frozen_string_literal: true

module Agents
  # Value object representing the outcome of a guard evaluation.
  # A guard can pass (no action), rewrite content, or tripwire (abort the run).
  #
  # @example Passing (no issues found)
  #   GuardResult.pass
  #
  # @example Rewriting content
  #   GuardResult.rewrite("redacted output", message: "PII removed")
  #
  # @example Tripwiring (aborting the run)
  #   GuardResult.tripwire(message: "Prompt injection detected")
  class GuardResult
    attr_reader :action, :content, :output, :message, :metadata

    # @param action [Symbol] :pass, :rewrite, or :tripwire
    # @param content [String, nil] Rewritten content as a String (only meaningful for :rewrite)
    # @param output [Object, nil] Type-preserved output — matches original input type (Hash/Array/String).
    #   Set by GuardRunner when structured content is serialized for guards and deserialized back.
    #   Defaults to content when not explicitly provided.
    # @param message [String] Human-readable explanation of the guard's decision
    # @param metadata [Hash] Arbitrary data for logging/instrumentation
    def initialize(action:, content: nil, output: nil, message: "", metadata: {})
      @action = action
      @content = content
      @output = output || content
      @message = message
      @metadata = metadata
    end

    def pass?     = action == :pass
    def rewrite?  = action == :rewrite
    def tripwire? = action == :tripwire

    # Create a passing result (no action needed).
    def self.pass(message: "", metadata: {})
      new(action: :pass, message: message, metadata: metadata)
    end

    # Create a rewrite result with replacement content.
    #
    # @param content [String] The rewritten content to use instead of the original
    def self.rewrite(content, message: "", metadata: {})
      new(action: :rewrite, content: content, message: message, metadata: metadata)
    end

    # Create a tripwire result that aborts the run.
    #
    # @param message [String] Explanation of why the run was aborted
    def self.tripwire(message:, metadata: {})
      new(action: :tripwire, message: message, metadata: metadata)
    end
  end
end
