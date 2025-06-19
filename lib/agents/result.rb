# frozen_string_literal: true

# Container for agent execution results.
# Provides a consistent interface for both successful and failed executions.
#
# @example Successful result
#   result = Agents::Result.new(success: true, output: "Hello!")
#   puts result.output if result.success?
#
# @example Error result
#   result = Agents::Result.new(success: false, error: "Something went wrong")
#   puts result.error unless result.success?
module Agents
  class Result
    attr_reader :input, :output, :error, :duration, :metadata

    # Initialize a new result
    # @param success [Boolean] Whether the execution was successful
    # @param input [String] The original input
    # @param output [String, nil] The agent's output (if successful)
    # @param error [String, nil] Error message (if failed)
    # @param duration [Float, nil] Execution duration in seconds
    # @param metadata [Hash] Additional metadata about the execution
    def initialize(success:, input: nil, output: nil, error: nil, duration: nil, metadata: {})
      @success = success
      @input = input
      @output = output
      @error = error
      @duration = duration
      @metadata = metadata || {}
    end

    # Check if the execution was successful
    # @return [Boolean] True if successful
    def success?
      @success
    end

    # Check if the execution failed
    # @return [Boolean] True if failed
    def failure?
      !@success
    end

    # Alias for consistency
    alias failed? failure?

    # Get the result content (output if success, error if failure)
    # @return [String] The result content
    def content
      success? ? @output : @error
    end

    # Get metadata value
    # @param key [Symbol, String] Metadata key
    # @return [Object] Metadata value
    def [](key)
      @metadata[key]
    end

    # Convert to hash representation
    # @return [Hash] Hash representation of the result
    def to_h
      {
        success: @success,
        input: @input,
        output: @output,
        error: @error,
        duration: @duration,
        metadata: @metadata
      }
    end

    # Convert to JSON
    # @return [String] JSON representation
    def to_json(*args)
      to_h.to_json(*args)
    end

    # String representation
    # @return [String] String representation of the result
    def to_s
      if success?
        "Success: #{@output}"
      else
        "Error: #{@error}"
      end
    end

    # Pretty inspect for debugging
    # @return [String] Detailed string representation
    def inspect
      status = success? ? "SUCCESS" : "FAILURE"
      content_preview = content&.to_s&.slice(0, 100)
      content_preview += "..." if content&.length.to_i > 100

      "#<Agents::Result #{status} duration=#{@duration}s content=\"#{content_preview}\">"
    end

    # Class methods for creating results

    class << self
      # Create a successful result
      # @param input [String] Original input
      # @param output [String] Agent output
      # @param duration [Float] Execution duration
      # @param metadata [Hash] Additional metadata
      # @return [Agents::Result] Success result
      def success(input:, output:, duration: nil, metadata: {})
        new(
          success: true,
          input: input,
          output: output,
          duration: duration,
          metadata: metadata
        )
      end

      # Create a failed result
      # @param input [String] Original input
      # @param error [String] Error message
      # @param duration [Float] Execution duration
      # @param metadata [Hash] Additional metadata
      # @return [Agents::Result] Error result
      def failure(input:, error:, duration: nil, metadata: {})
        new(
          success: false,
          input: input,
          error: error,
          duration: duration,
          metadata: metadata
        )
      end

      # Alias for consistency
      alias error failure
    end
  end
end
