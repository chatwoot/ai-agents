# frozen_string_literal: true

module Agents
  module Evaluation
    class CoordinationMetrics
      def evaluate(execution_result)
        handoffs = execution_result.handoffs

        handoff_analysis = analyze_handoffs(handoffs)
        context_analysis = analyze_context_preservation(execution_result)
        efficiency_analysis = analyze_efficiency(execution_result)

        {
          handoff_count: handoffs.count,
          handoffs: handoff_analysis[:handoffs],
          circular_patterns: handoff_analysis[:circular_patterns],
          context_preserved: context_analysis[:preserved],
          context_issues: context_analysis[:issues],
          efficiency_score: efficiency_analysis[:score],
          efficiency_issues: efficiency_analysis[:issues],
          overall_coordination_score: calculate_coordination_score(handoff_analysis, context_analysis,
                                                                   efficiency_analysis)
        }
      end

      private

      def analyze_handoffs(handoffs)
        return { handoffs: [], circular_patterns: [] } if handoffs.empty?

        # Build handoff chain
        handoff_chain = handoffs.map { |h| [h[:from], h[:to]] }

        # Detect circular patterns
        circular_patterns = detect_circular_patterns(handoff_chain)

        # Analyze individual handoffs
        handoff_details = handoffs.map.with_index do |handoff, index|
          {
            sequence: index + 1,
            from: handoff[:from],
            to: handoff[:to],
            reason: handoff[:reason],
            appropriate: assess_handoff_appropriateness(handoff, index, handoffs)
          }
        end

        {
          handoffs: handoff_details,
          circular_patterns: circular_patterns,
          total_agents: handoff_chain.flatten.uniq.count
        }
      end

      def detect_circular_patterns(handoff_chain)
        return [] if handoff_chain.length < 2

        circular_patterns = []

        # Look for immediate back-and-forth (A -> B -> A)
        handoff_chain.each_cons(2).with_index do |(first, second), index|
          if first[1] == second[0] && first[0] == second[1]
            circular_patterns << {
              type: "immediate_return",
              pattern: "#{first[0]} → #{first[1]} → #{second[1]}",
              positions: [index, index + 1]
            }
          end
        end

        # Look for longer cycles (A -> B -> C -> A)
        agents_visited = []
        handoff_chain.each_with_index do |(from, to), index|
          if agents_visited.include?(to) && agents_visited.last != to
            cycle_start = agents_visited.index(to)
            cycle = agents_visited[cycle_start..] + [to]
            circular_patterns << {
              type: "cycle",
              pattern: cycle.join(" → "),
              positions: (cycle_start..index).to_a
            }
          end
          agents_visited << from unless agents_visited.include?(from)
          agents_visited << to
        end

        circular_patterns.uniq
      end

      def assess_handoff_appropriateness(handoff, index, all_handoffs)
        # Basic heuristics for handoff appropriateness
        reason = handoff[:reason].to_s.downcase

        # Good reasons for handoffs
        good_reasons = %w[
          billing technical support specialist escalation
          expertise department specific complex
        ]

        # Bad reasons (vague or unnecessary)
        bad_reasons = %w[
          unclear confused unsure maybe possibly
          general help assistance
        ]

        # Check if reason contains good indicators
        has_good_reason = good_reasons.any? { |word| reason.include?(word) }
        has_bad_reason = bad_reasons.any? { |word| reason.include?(word) }

        # Check for immediate return to previous agent
        if index.positive?
          previous_handoff = all_handoffs[index - 1]
          if previous_handoff[:from] == handoff[:to]
            return {
              appropriate: false,
              issue: "Immediate return to previous agent",
              confidence: 0.9
            }
          end
        end

        if has_good_reason && !has_bad_reason
          { appropriate: true, confidence: 0.8 }
        elsif has_bad_reason
          {
            appropriate: false,
            issue: "Vague handoff reason",
            confidence: 0.7
          }
        else
          { appropriate: true, confidence: 0.5 } # Neutral
        end
      end

      def analyze_context_preservation(execution_result)
        # This is a simplified analysis - in a real implementation,
        # you might analyze the actual conversation context

        handoffs = execution_result.handoffs
        return { preserved: true, issues: [] } if handoffs.empty?

        issues = []

        # Check for potential context loss indicators
        issues << "Multiple handoffs may lead to context loss" if handoffs.count > 2

        # Check if agents are asking for information that should be available
        output = execution_result.output.to_s.downcase
        context_loss_indicators = [
          "what was your name again",
          "can you repeat",
          "what was the issue",
          "start over",
          "from the beginning"
        ]

        if context_loss_indicators.any? { |indicator| output.include?(indicator) }
          issues << "Agent appears to have lost previous context"
        end

        # For now, assume context is preserved unless we find issues
        preserved = issues.empty?

        {
          preserved: preserved,
          issues: issues,
          handoff_count: handoffs.count
        }
      end

      def analyze_efficiency(execution_result)
        handoffs = execution_result.handoffs
        duration = execution_result.duration

        issues = []

        # Too many handoffs for simple tasks
        issues << "Excessive handoffs (#{handoffs.count}) may indicate poor routing" if handoffs.count > 3

        # Very long duration might indicate inefficiency
        issues << "Long execution time (#{duration.round(1)}s) may indicate inefficiency" if duration > 30 # seconds

        # Calculate efficiency score
        score = calculate_efficiency_score(handoffs.count, duration, issues.count)

        {
          score: score,
          issues: issues,
          handoff_efficiency: handoffs.empty? ? 1.0 : [1.0 - (handoffs.count * 0.1), 0.1].max,
          time_efficiency: duration < 10 ? 1.0 : [1.0 - (duration / 60.0), 0.1].max
        }
      end

      def calculate_efficiency_score(handoff_count, duration, issue_count)
        # Base score
        score = 1.0

        # Penalize excessive handoffs
        score -= handoff_count * 0.1

        # Penalize long duration (more than 10 seconds)
        if duration > 10
          score -= (duration - 10) / 60.0 # 1 point per minute over 10 seconds
        end

        # Penalize identified issues
        score -= issue_count * 0.2

        # Ensure score is between 0 and 1
        [[score, 0.0].max, 1.0].min.round(2)
      end

      def calculate_coordination_score(handoff_analysis, context_analysis, efficiency_analysis)
        # Weighted average of coordination aspects
        handoff_score = handoff_analysis[:circular_patterns].empty? ? 1.0 : 0.3
        context_score = context_analysis[:preserved] ? 1.0 : 0.4
        efficiency_score = efficiency_analysis[:score]

        weighted_score = (handoff_score * 0.4) + (context_score * 0.4) + (efficiency_score * 0.2)
        weighted_score.round(2)
      end
    end
  end
end
