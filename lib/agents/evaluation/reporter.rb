# frozen_string_literal: true

module Agents
  module Evaluation
    class Reporter
      def output(results)
        print_console_output(results)
        write_json_output(results)
        results
      end

      private

      def print_console_output(results)
        print_header
        print_quality_section(results)
        print_coordination_section(results)
        print_summary(results)
      end

      def print_header
        puts "\nAgents Evaluation\n\n"
      end

      def print_quality_section(results)
        puts "Quality Assessment"

        results.scenario_results.each do |scenario_result|
          print_scenario_result(scenario_result)
        end

        puts
      end

      def print_coordination_section(results)
        return unless results.has_coordination_issues?

        puts "Coordination Analysis"

        # Print circular handoff warnings
        results.scenario_results.each do |scenario_result|
          circular_patterns = scenario_result.coordination_assessment[:circular_patterns]
          next if circular_patterns.nil? || circular_patterns.empty?

          circular_patterns.each do |pattern|
            puts "  ⚠ Circular handoff detected in '#{scenario_result.scenario.name}': #{pattern[:pattern]}"
          end
        end

        # Print context preservation issues
        context_issues = results.coordination_summary[:context_issues]
        if context_issues.positive?
          puts "  ⚠ Context preservation issues in #{context_issues} scenario#{"s" if context_issues != 1}"
        end

        puts
      end

      def print_scenario_result(scenario_result)
        status_icon = scenario_result.passed? ? "✓" : "✗"
        duration = format_duration(scenario_result.duration)

        puts "  #{status_icon} #{scenario_result.scenario.name} (#{duration})"

        # Print issues if scenario failed
        puts "    #{scenario_result.primary_issue}" if scenario_result.failed? && scenario_result.primary_issue

        # Print warnings
        scenario_result.warnings.each do |warning|
          puts "    ⚠ #{warning}"
        end
      end

      def print_summary(results)
        total = results.total_count
        passed = results.passed_count
        failed = results.failed_count

        puts "#{total} scenario#{"s" if total != 1}, #{passed} passed, #{failed} failed"

        # Print quality score
        quality_score = (results.quality_score * 100).round
        puts "Quality Score: #{quality_score}/100"

        # Print coordination summary
        if results.has_coordination_issues?
          coordination_issues = count_coordination_issues(results)
          puts "Coordination: #{coordination_issues} issue#{"s" if coordination_issues != 1} found"
        end

        # Print top issues
        top_issues = results.top_issues
        if top_issues.any?
          puts "\nTop Issues:"
          top_issues.first(3).each do |issue|
            puts "• #{issue}"
          end
        end

        # Print insights
        insights = results.insights
        if insights.any?
          puts "\nInsights:"
          insights.first(3).each do |insight|
            puts "• #{insight}"
          end
        end

        puts
      end

      def write_json_output(results)
        json_data = results.to_h
        filename = "evaluation_results.json"

        File.write(filename, JSON.pretty_generate(json_data))
        puts "Results saved to: #{filename}"
      end

      def format_duration(duration)
        if duration < 1
          "#{(duration * 1000).round}ms"
        elsif duration < 60
          "#{duration.round(1)}s"
        else
          minutes = (duration / 60).floor
          seconds = (duration % 60).round
          "#{minutes}m #{seconds}s"
        end
      end

      def count_coordination_issues(results)
        issue_count = 0

        # Count circular patterns
        results.scenario_results.each do |scenario_result|
          circular_patterns = scenario_result.coordination_assessment[:circular_patterns]
          issue_count += circular_patterns.count if circular_patterns
        end

        # Count context issues
        issue_count += results.coordination_summary[:context_issues]

        issue_count
      end
    end
  end
end
