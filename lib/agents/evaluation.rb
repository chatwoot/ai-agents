# frozen_string_literal: true

require "yaml"
require "json"

module Agents
  module Evaluation
    require_relative "evaluation/scenario"
    require_relative "evaluation/result"
    require_relative "evaluation/quality_metrics"
    require_relative "evaluation/coordination_metrics"
    require_relative "evaluation/reporter"

    class << self
      def run(agent_runner, scenarios_path = nil)
        new(agent_runner).run(scenarios_path)
      end
    end

    def self.new(agent_runner)
      Evaluator.new(agent_runner)
    end

    class Evaluator
      def initialize(agent_runner)
        @agent_runner = agent_runner
        @quality_metrics = QualityMetrics.new
        @coordination_metrics = CoordinationMetrics.new
        @reporter = Reporter.new
      end

      def run(scenarios_path = nil)
        scenarios = load_scenarios(scenarios_path)
        scenario_results = evaluate_scenarios(scenarios)
        results = build_evaluation_results(scenario_results)
        @reporter.output(results)
        results
      end

      private

      def load_scenarios(scenarios_path)
        path = scenarios_path || default_scenarios_path
        return [] unless File.exist?(path)

        if File.directory?(path)
          load_scenarios_from_directory(path)
        else
          load_scenarios_from_file(path)
        end
      end

      def default_scenarios_path
        File.join(Dir.pwd, "spec", "scenarios")
      end

      def load_scenarios_from_directory(directory)
        scenarios = []
        Dir.glob(File.join(directory, "*.yml")).each do |file|
          scenarios.concat(load_scenarios_from_file(file))
        end
        scenarios
      end

      def load_scenarios_from_file(file)
        yaml_data = YAML.load_file(file)
        yaml_data.map { |scenario_data| Scenario.new(scenario_data) }
      rescue StandardError => e
        puts "Warning: Failed to load scenarios from #{file}: #{e.message}"
        []
      end

      def evaluate_scenarios(scenarios)
        scenarios.map do |scenario|
          evaluate_single_scenario(scenario)
        end
      end

      def evaluate_single_scenario(scenario)
        execution_data = setup_execution_tracking
        start_time = Time.now

        begin
          result = @agent_runner.run(scenario.input)
          duration = Time.now - start_time

          execution_result = Result::ExecutionResult.new(
            scenario: scenario,
            agent_result: result,
            execution_data: execution_data,
            duration: duration
          )

          quality_assessment = @quality_metrics.evaluate(execution_result)
          coordination_assessment = @coordination_metrics.evaluate(execution_result)

          Result::ScenarioResult.new(
            execution_result: execution_result,
            quality_assessment: quality_assessment,
            coordination_assessment: coordination_assessment
          )
        rescue StandardError => e
          Result::ScenarioResult.new_failed(scenario, e, Time.now - start_time)
        end
      end

      def setup_execution_tracking
        execution_data = {
          tools_used: [],
          handoffs: [],
          agents_involved: [],
          errors: []
        }

        @agent_runner.on_tool_complete do |tool_name, result|
          execution_data[:tools_used] << { name: tool_name, result: result }
        end

        @agent_runner.on_agent_handoff do |from_agent, to_agent, reason|
          execution_data[:handoffs] << { from: from_agent, to: to_agent, reason: reason }
          execution_data[:agents_involved] << from_agent unless execution_data[:agents_involved].include?(from_agent)
          execution_data[:agents_involved] << to_agent unless execution_data[:agents_involved].include?(to_agent)
        end

        execution_data
      end

      def build_evaluation_results(scenario_results)
        quality_summary = build_quality_summary(scenario_results)
        coordination_summary = build_coordination_summary(scenario_results)

        Result::EvaluationResults.new(
          scenario_results: scenario_results,
          quality_summary: quality_summary,
          coordination_summary: coordination_summary
        )
      end

      def build_quality_summary(scenario_results)
        passed = scenario_results.count(&:passed?)
        total = scenario_results.count
        score = total.zero? ? 0.0 : passed.to_f / total

        {
          passed: passed,
          total: total,
          score: score,
          issues: scenario_results.reject(&:passed?).map(&:primary_issue).compact
        }
      end

      def build_coordination_summary(scenario_results)
        all_handoffs = scenario_results.flat_map { |r| r.coordination_assessment[:handoffs] || [] }
        circular_patterns = scenario_results.flat_map { |r| r.coordination_assessment[:circular_patterns] || [] }

        {
          total_handoffs: all_handoffs.count,
          circular_patterns: circular_patterns,
          context_issues: scenario_results.count { |r| r.coordination_assessment[:context_preserved] == false }
        }
      end
    end
  end
end
