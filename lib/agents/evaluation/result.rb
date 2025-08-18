# frozen_string_literal: true

module Agents
  module Evaluation
    module Result
      class ExecutionResult
        attr_reader :scenario, :agent_result, :execution_data, :duration

        def initialize(scenario:, agent_result:, execution_data:, duration:)
          @scenario = scenario
          @agent_result = agent_result
          @execution_data = execution_data
          @duration = duration
        end

        def final_agent
          return nil unless @agent_result&.context

          # Try to get current agent from context
          current_agent = @agent_result.context.current_agent
          return current_agent.name if current_agent

          # Fallback: get last agent from handoffs
          last_handoff = @execution_data[:handoffs].last
          return last_handoff[:to] if last_handoff

          # Final fallback: assume first agent if no handoffs
          nil
        end

        def tools_used
          @execution_data[:tools_used].map { |tool| tool[:name] }
        end

        def handoffs
          @execution_data[:handoffs]
        end

        def agents_involved
          @execution_data[:agents_involved]
        end

        def completed?
          # Basic completion check - agent returned a result and no critical errors
          !@agent_result.nil? &&
            !@agent_result.output.nil? &&
            !@agent_result.output.empty? &&
            @execution_data[:errors].none? { |error| error[:critical] }
        end

        def output
          @agent_result&.output
        end

        def context
          @agent_result&.context
        end
      end

      class ScenarioResult
        attr_reader :execution_result, :quality_assessment, :coordination_assessment,
                    :error, :duration

        def initialize(execution_result:, quality_assessment:, coordination_assessment:)
          @execution_result = execution_result
          @quality_assessment = quality_assessment
          @coordination_assessment = coordination_assessment
          @error = nil
        end

        def self.new_failed(scenario, error, duration)
          result = allocate
          result.instance_variable_set(:@execution_result,
                                       ExecutionResult.new(scenario: scenario, agent_result: nil, execution_data: {},
                                                           duration: duration))
          result.instance_variable_set(:@quality_assessment, {})
          result.instance_variable_set(:@coordination_assessment, {})
          result.instance_variable_set(:@error, error)
          result.instance_variable_set(:@duration, duration)
          result
        end

        def scenario
          @execution_result.scenario
        end

        def passed?
          return false if @error

          # Check quality metrics
          quality_passed = @quality_assessment[:overall_score] && @quality_assessment[:overall_score] >= 0.5

          # Check coordination metrics (warnings don't fail the scenario)
          coordination_issues = @coordination_assessment[:circular_patterns]&.any? || false

          quality_passed && !coordination_issues
        end

        def failed?
          !passed?
        end

        def primary_issue
          return @error.message if @error

          issues = []

          # Collect quality issues
          issues << @quality_assessment[:completion_issue] if @quality_assessment[:completion_issue]

          issues << @quality_assessment[:agent_issue] if @quality_assessment[:agent_issue]

          issues << @quality_assessment[:tool_issue] if @quality_assessment[:tool_issue]

          # Collect coordination issues
          issues << "Circular handoff detected" if @coordination_assessment[:circular_patterns]&.any?

          issues << "Context lost during handoffs" if @coordination_assessment[:context_preserved] == false

          issues.first
        end

        def all_issues
          issues = []
          issues << @error.message if @error

          # Quality issues
          [@quality_assessment[:completion_issue],
           @quality_assessment[:agent_issue],
           @quality_assessment[:tool_issue]].compact.each do |issue|
            issues << issue
          end

          # Coordination issues
          issues << "Circular handoff patterns detected" if @coordination_assessment[:circular_patterns]&.any?

          issues << "Context not preserved across handoffs" if @coordination_assessment[:context_preserved] == false

          issues
        end

        def warnings
          warnings = []

          # Coordination warnings
          if @coordination_assessment[:handoff_count] && @coordination_assessment[:handoff_count] > 3
            warnings << "High number of handoffs (#{@coordination_assessment[:handoff_count]})"
          end

          if @coordination_assessment[:efficiency_score] && @coordination_assessment[:efficiency_score] < 0.7
            warnings << "Low coordination efficiency"
          end

          warnings
        end

        def to_h
          {
            scenario_name: scenario.name,
            passed: passed?,
            duration: @duration,
            issues: all_issues,
            warnings: warnings,
            quality_score: @quality_assessment[:overall_score],
            coordination_metrics: @coordination_assessment
          }
        end
      end

      class EvaluationResults
        attr_reader :scenario_results, :quality_summary, :coordination_summary

        def initialize(scenario_results:, quality_summary:, coordination_summary:)
          @scenario_results = scenario_results
          @quality_summary = quality_summary
          @coordination_summary = coordination_summary
        end

        def passed_count
          @scenario_results.count(&:passed?)
        end

        def failed_count
          @scenario_results.count(&:failed?)
        end

        def total_count
          @scenario_results.count
        end

        def overall_score
          return 0.0 if total_count.zero?

          passed_count.to_f / total_count
        end

        def quality_score
          @quality_summary[:score] || 0.0
        end

        def has_coordination_issues?
          @coordination_summary[:circular_patterns].any? ||
            @coordination_summary[:context_issues].positive?
        end

        def top_issues
          issue_counts = Hash.new(0)

          @scenario_results.each do |result|
            result.all_issues.each { |issue| issue_counts[issue] += 1 }
          end

          issue_counts.sort_by { |_issue, count| -count }.first(5).map(&:first)
        end

        def insights
          insights = []

          # Quality insights
          insights << "Quality score below threshold (#{(quality_score * 100).round}%)" if quality_score < 0.7

          # Coordination insights
          if @coordination_summary[:circular_patterns].any?
            insights << "Circular handoff patterns detected in #{@coordination_summary[:circular_patterns].count} scenarios"
          end

          if @coordination_summary[:context_issues].positive?
            insights << "Context preservation issues in #{@coordination_summary[:context_issues]} scenarios"
          end

          # Tool insights
          failed_scenarios = @scenario_results.select(&:failed?)
          tool_failures = failed_scenarios.count { |s| s.primary_issue&.include?("tool") }
          insights << "Tool-related failures in #{tool_failures} scenarios" if tool_failures.positive?

          insights
        end

        def to_h
          {
            summary: {
              total: total_count,
              passed: passed_count,
              failed: failed_count,
              overall_score: overall_score,
              quality_score: quality_score,
              has_coordination_issues: has_coordination_issues?
            },
            scenarios: @scenario_results.map(&:to_h),
            insights: insights,
            top_issues: top_issues
          }
        end
      end
    end
  end
end
