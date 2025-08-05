# frozen_string_literal: true

module Agents
  module Evaluation
    class QualityMetrics
      def evaluate(execution_result)
        execution_result.scenario

        completion_assessment = assess_completion(execution_result)
        agent_assessment = assess_final_agent(execution_result)
        tool_assessment = assess_tool_usage(execution_result)
        clarification_assessment = assess_clarification(execution_result)

        overall_score = calculate_overall_score(
          completion_assessment,
          agent_assessment,
          tool_assessment,
          clarification_assessment
        )

        {
          overall_score: overall_score,
          completion: completion_assessment,
          agent_routing: agent_assessment,
          tool_usage: tool_assessment,
          clarification: clarification_assessment,
          completion_issue: completion_assessment[:issue],
          agent_issue: agent_assessment[:issue],
          tool_issue: tool_assessment[:issue]
        }
      end

      private

      def assess_completion(execution_result)
        scenario = execution_result.scenario
        expected_completion = scenario.expected_completion?
        actual_completion = execution_result.completed?

        if expected_completion.nil?
          # No expectation set, just check if it completed
          {
            score: actual_completion ? 1.0 : 0.5,
            expected: nil,
            actual: actual_completion,
            passed: true,
            issue: actual_completion ? nil : "Task did not complete"
          }
        elsif expected_completion == actual_completion
          # Expectation matches reality
          {
            score: 1.0,
            expected: expected_completion,
            actual: actual_completion,
            passed: true,
            issue: nil
          }
        else
          # Expectation doesn't match
          issue = if expected_completion && !actual_completion
                    "Expected task to complete but it didn't"
                  else
                    "Expected task not to complete but it did"
                  end

          {
            score: 0.0,
            expected: expected_completion,
            actual: actual_completion,
            passed: false,
            issue: issue
          }
        end
      end

      def assess_final_agent(execution_result)
        scenario = execution_result.scenario
        expected_agent = scenario.expected_final_agent
        actual_agent = execution_result.final_agent

        if expected_agent.nil?
          # No expectation set
          {
            score: 1.0,
            expected: nil,
            actual: actual_agent,
            passed: true,
            issue: nil
          }
        elsif normalize_agent_name(expected_agent) == normalize_agent_name(actual_agent)
          # Matches expectation
          {
            score: 1.0,
            expected: expected_agent,
            actual: actual_agent,
            passed: true,
            issue: nil
          }
        else
          # Doesn't match expectation
          {
            score: 0.0,
            expected: expected_agent,
            actual: actual_agent,
            passed: false,
            issue: "Expected final agent '#{expected_agent}' but got '#{actual_agent}'"
          }
        end
      end

      def assess_tool_usage(execution_result)
        scenario = execution_result.scenario
        expected_tools = scenario.expected_tools
        actual_tools = execution_result.tools_used

        if expected_tools.empty?
          # No specific tool expectations
          {
            score: 1.0,
            expected: [],
            actual: actual_tools,
            passed: true,
            issue: nil
          }
        else
          # Check if all expected tools were used
          missing_tools = expected_tools - actual_tools.map(&:to_s)
          unexpected_tools = actual_tools.map(&:to_s) - expected_tools

          if missing_tools.empty?
            score = unexpected_tools.empty? ? 1.0 : 0.8 # Slight penalty for unexpected tools
            {
              score: score,
              expected: expected_tools,
              actual: actual_tools,
              missing: missing_tools,
              unexpected: unexpected_tools,
              passed: true,
              issue: unexpected_tools.empty? ? nil : "Used unexpected tools: #{unexpected_tools.join(", ")}"
            }
          else
            {
              score: 0.3, # Partial credit for other aspects
              expected: expected_tools,
              actual: actual_tools,
              missing: missing_tools,
              unexpected: unexpected_tools,
              passed: false,
              issue: "Missing required tools: #{missing_tools.join(", ")}"
            }
          end
        end
      end

      def assess_clarification(execution_result)
        scenario = execution_result.scenario
        should_clarify = scenario.should_clarify?

        if should_clarify.nil?
          # No expectation about clarification
          {
            score: 1.0,
            expected: nil,
            passed: true,
            issue: nil
          }
        else
          # Check if clarification was requested (heuristic based on output)
          output = execution_result.output || ""
          asked_clarification = contains_clarification_request?(output)

          if should_clarify == asked_clarification
            {
              score: 1.0,
              expected: should_clarify,
              actual: asked_clarification,
              passed: true,
              issue: nil
            }
          else
            issue = if should_clarify && !asked_clarification
                      "Expected clarification request but none found"
                    else
                      "Unexpected clarification request"
                    end

            {
              score: 0.2,
              expected: should_clarify,
              actual: asked_clarification,
              passed: false,
              issue: issue
            }
          end
        end
      end

      def calculate_overall_score(completion, agent, tool, clarification)
        scores = [completion[:score], agent[:score], tool[:score], clarification[:score]]
        weights = [0.4, 0.3, 0.2, 0.1] # Completion is most important

        weighted_sum = scores.zip(weights).sum { |score, weight| score * weight }
        weighted_sum.round(2)
      end

      def normalize_agent_name(name)
        return nil if name.nil?

        name.to_s.downcase.strip
      end

      def contains_clarification_request?(output)
        clarification_patterns = [
          /can you (?:please )?(?:be more specific|provide more details|clarify)/i,
          /(?:what|which|how) (?:specifically|exactly)/i,
          /could you (?:please )?(?:tell me more|elaborate)/i,
          /i need more (?:information|details)/i,
          /can you help me understand/i,
          /\?.*(?:more|specific|detail|clarify)/i
        ]

        clarification_patterns.any? { |pattern| output.match?(pattern) }
      end
    end
  end
end
