# frozen_string_literal: true

module Agents
  module Evaluation
    class Scenario
      attr_reader :name, :input, :expectations, :metadata

      def initialize(data)
        @data = data.is_a?(Hash) ? data : data.to_h
        @name = @data["name"] || @data[:name] || "unnamed_scenario"
        @input = @data["input"] || @data[:input] || ""
        @expectations = parse_expectations(@data["expect"] || @data[:expect] || {})
        @metadata = @data["metadata"] || @data[:metadata] || {}
      end

      def expected_completion?
        @expectations[:completes]
      end

      def expected_final_agent
        @expectations[:final_agent]
      end

      def expected_tools
        @expectations[:uses_tools] || []
      end

      def should_clarify?
        @expectations[:clarifies]
      end

      def should_escalate?
        @expectations[:escalates]
      end

      def valid?
        !@input.empty?
      end

      def to_h
        {
          name: @name,
          input: @input,
          expectations: @expectations,
          metadata: @metadata
        }
      end

      private

      def parse_expectations(expect_data)
        return {} if expect_data.nil? || expect_data.empty?

        expectations = {}

        # Handle different ways to specify completion
        expectations[:completes] = parse_boolean_expectation(expect_data, "completes", "completed", "resolves")

        # Handle agent expectations
        expectations[:final_agent] = expect_data["final_agent"] ||
                                     expect_data["agent_ends_with"] ||
                                     expect_data["ends_with_agent"]

        # Handle tool expectations
        expectations[:uses_tools] = parse_array_expectation(expect_data, "uses_tools", "tools_used", "requires_tools")

        # Handle behavioral expectations
        expectations[:clarifies] = parse_boolean_expectation(expect_data, "clarifies", "asks_for_clarification")
        expectations[:escalates] = parse_boolean_expectation(expect_data, "escalates", "escalation_attempted")

        # Handle custom expectations
        expect_data.each do |key, value|
          next if %w[completes completed resolves final_agent agent_ends_with ends_with_agent
                     uses_tools tools_used requires_tools clarifies asks_for_clarification
                     escalates escalation_attempted].include?(key.to_s)

          expectations[key.to_sym] = value
        end

        expectations
      end

      def parse_boolean_expectation(data, *keys)
        keys.each do |key|
          value = data[key] || data[key.to_sym]
          return value if [true, false].include?(value)
        end
        nil
      end

      def parse_array_expectation(data, *keys)
        keys.each do |key|
          value = data[key] || data[key.to_sym]
          next unless value

          return Array(value).map(&:to_s) if value
        end
        []
      end
    end
  end
end
