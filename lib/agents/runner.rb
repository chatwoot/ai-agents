# frozen_string_literal: true

# Simple execution runner for agents.
# Handles basic agent execution with minimal orchestration for Phase 1.
#
# @example Basic usage
#   runner = Agents::Runner.new(agent)
#   result = runner.execute("Hello")
module Agents
  class Runner
    # Runner execution errors
    class RunnerError < Agents::Error; end
    class ConfigurationError < RunnerError; end

    # Default configuration for runner
    DEFAULT_CONFIG = {
      max_turns: 10,
      timeout: 300, # 5 minutes
      trace_execution: false
    }.freeze

    # Initialize a new runner
    # @param agent [Agents::Agent] The agent to run
    # @param config [Hash] Runner configuration
    def initialize(agent, config = {})
      @agent = agent
      @config = DEFAULT_CONFIG.merge(config)
      validate_configuration!
    end

    # Execute the agent with the given input
    # @param input [String] User input
    # @param context [Hash] Execution context
    # @return [Agents::Result] Execution result
    def execute(input, context = {})
      start_time = Time.now

      begin
        # For Phase 1, we do simple direct execution
        response = @agent.call(input, context: context)

        end_time = Time.now
        duration = end_time - start_time

        create_success_result(
          input: input,
          output: response,
          duration: duration,
          context: context
        )
      rescue StandardError => e
        end_time = Time.now
        duration = end_time - start_time

        create_error_result(
          input: input,
          error: e,
          duration: duration,
          context: context
        )
      end
    end

    # Execute with streaming (placeholder for future implementation)
    # @param input [String] User input
    # @param context [Hash] Execution context
    # @yield [String] Streaming response chunks
    # @return [Agents::Result] Final result
    def execute_streaming(input, context = {}, &block)
      # For Phase 1, just do regular execution and yield the full result
      result = execute(input, context)
      block&.call(result.output)
      result
    end

    # Get runner configuration
    # @return [Hash] Current configuration
    def config
      @config.dup
    end

    private

    # Validate runner configuration
    # @raise [ConfigurationError] If configuration is invalid
    def validate_configuration!
      raise ConfigurationError, "Agent must respond to :call" unless @agent.respond_to?(:call)

      unless @config[:max_turns].is_a?(Integer) && @config[:max_turns].positive?
        raise ConfigurationError, "max_turns must be a positive integer"
      end

      return if @config[:timeout].is_a?(Numeric) && @config[:timeout].positive?

      raise ConfigurationError, "timeout must be a positive number"
    end

    # Create a successful result
    # @param input [String] Original input
    # @param output [String] Agent output
    # @param duration [Float] Execution duration
    # @param context [Hash] Execution context
    # @return [Agents::Result] Success result
    def create_success_result(input:, output:, duration:, context:)
      Agents::Result.new(
        success: true,
        input: input,
        output: output,
        error: nil,
        duration: duration,
        metadata: {
          agent: @agent.class.name,
          config: @config,
          context: context
        }
      )
    end

    # Create an error result
    # @param input [String] Original input
    # @param error [Exception] The error that occurred
    # @param duration [Float] Execution duration
    # @param context [Hash] Execution context
    # @return [Agents::Result] Error result
    def create_error_result(input:, error:, duration:, context:)
      Agents::Result.new(
        success: false,
        input: input,
        output: nil,
        error: error.message,
        duration: duration,
        metadata: {
          agent: @agent.class.name,
          config: @config,
          context: context,
          error_class: error.class.name,
          backtrace: error.backtrace&.first(5)
        }
      )
    end
  end
end
