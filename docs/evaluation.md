# Evaluation Framework

The Agents SDK includes a comprehensive evaluation framework for testing conversation quality and multi-agent coordination. It provides automated assessment of agent performance with minimal setup.

## Quick Start

```ruby
# Basic usage - auto-discovers scenarios in spec/scenarios/
results = Agents::Evaluation.run(agent_runner)

# Custom scenario path
results = Agents::Evaluation.run(agent_runner, "path/to/scenarios")

# Access results programmatically
puts "Overall score: #{results.overall_score}"
puts "Issues found: #{results.top_issues}"
```

## Output Format

The framework provides both human-readable console output and machine-readable JSON:

### Console Output (RSpec-style)
```
Agents Evaluation

Quality Assessment
  ✓ double_charge_complaint (0.8s)
  ✗ billing_question_vague (1.2s)
    Expected clarification request but none found
  ✓ payment_method_update (0.6s)

Coordination Analysis
  ⚠ Circular handoff detected in 'complex_issue': triage → support → triage

3 scenarios, 2 passed, 1 failed
Quality Score: 67/100
Coordination: 1 issue found

Top Issues:
• Expected clarification request but none found
• Circular handoff patterns detected

Results saved to: evaluation_results.json
```

### JSON Output
```json
{
  "summary": {
    "total": 3,
    "passed": 2,
    "failed": 1,
    "overall_score": 0.67,
    "quality_score": 0.67,
    "has_coordination_issues": true
  },
  "scenarios": [...],
  "insights": [
    "Quality score below threshold (67%)",
    "Circular handoff patterns detected in 1 scenarios"
  ],
  "top_issues": [
    "Expected clarification request but none found"
  ]
}
```

## Scenario Format

Scenarios are defined in YAML files with simple expectation syntax:

```yaml
# spec/scenarios/billing.yml
- name: double_charge_complaint
  input: "I was charged twice for my internet service this month"
  expect:
    completes: true
    final_agent: billing
    uses_tools: [account_lookup]

- name: billing_question_vague
  input: "I have a question about my bill"
  expect:
    completes: false
    clarifies: true
    final_agent: billing

- name: refund_request
  input: "I want a refund for last month's service outage"
  expect:
    completes: true
    final_agent: billing
    escalates: true
```

### Expectation Types

| Expectation | Type | Description |
|-------------|------|-------------|
| `completes` | boolean | Should the task be completed? |
| `final_agent` | string | Which agent should handle the final response? |
| `uses_tools` | array | Which tools should be used? |
| `clarifies` | boolean | Should the agent ask for clarification? |
| `escalates` | boolean | Should the issue be escalated? |

## Evaluation Metrics

### Quality Assessment
- **Task Completion**: Did the conversation achieve its intended goal?
- **Agent Routing**: Did the conversation end with the expected agent?
- **Tool Usage**: Were the appropriate tools used?
- **Clarification Handling**: Did agents appropriately request more information?

### Coordination Analysis
- **Handoff Appropriateness**: Were agent transfers necessary and well-reasoned?
- **Circular Pattern Detection**: Identifies A→B→A and longer cycles
- **Context Preservation**: Is information maintained across handoffs?
- **Efficiency**: Are conversations resolved with minimal handoffs?

## Integration Patterns

### CI/CD Integration
```bash
# Run evaluations in your CI pipeline
ruby -e "
require './lib/agents'
results = Agents::Evaluation.run(agent_runner)
exit 1 if results.overall_score < 0.7
"
```

### Custom Expectations
```yaml
- name: custom_scenario
  input: "Complex user request"
  expect:
    completes: true
    custom_metric: "expected_value"
    # Any key-value pairs become expectations
```

### Programmatic Access
```ruby
evaluator = Agents::Evaluation::Evaluator.new(agent_runner)
results = evaluator.run("spec/scenarios")

# Access detailed results
results.scenario_results.each do |scenario_result|
  if scenario_result.failed?
    puts scenario_result.primary_issue
    puts scenario_result.all_issues
  end
end

# Quality metrics breakdown
quality = scenario_result.quality_assessment
puts "Completion score: #{quality[:completion][:score]}"
puts "Agent routing score: #{quality[:agent_routing][:score]}"

# Coordination analysis
coordination = scenario_result.coordination_assessment
puts "Handoffs: #{coordination[:handoff_count]}"
puts "Circular patterns: #{coordination[:circular_patterns]}"
```

## Advanced Usage

### Custom Metrics
The framework can be extended with custom quality metrics:

```ruby
class CustomQualityMetrics < Agents::Evaluation::QualityMetrics
  def evaluate(execution_result)
    base_assessment = super
    base_assessment[:custom_score] = assess_custom_criteria(execution_result)
    base_assessment
  end

  private

  def assess_custom_criteria(execution_result)
    # Your custom evaluation logic
  end
end
```

### Real-time Monitoring
Leverage the existing callback system for live evaluation:

```ruby
evaluator = Agents::Evaluation::Evaluator.new(agent_runner)

# Monitor evaluation in real-time
agent_runner.on_agent_handoff do |from, to, reason|
  puts "Handoff: #{from} → #{to} (#{reason})"
end

results = evaluator.run
```

### Scenario Organization
Organize scenarios by feature or user journey:

```
spec/scenarios/
├── billing/
│   ├── payments.yml
│   ├── disputes.yml
│   └── refunds.yml
├── support/
│   ├── technical.yml
│   └── connectivity.yml
└── edge_cases/
    └── error_handling.yml
```

## Best Practices

### Scenario Design
- **Realistic inputs**: Use actual customer language, not sanitized examples
- **Edge cases**: Test vague requests, angry customers, and error conditions
- **Failure modes**: Include scenarios where completion is not expected
- **Mixed contexts**: Test scenarios requiring multiple agent types

### Example Edge Cases
```yaml
- name: extremely_vague_request
  input: "Help me"
  expect:
    completes: false
    clarifies: true

- name: angry_customer
  input: "This is ridiculous! Cancel my service immediately!"
  expect:
    escalates: true
    completes: false

- name: mixed_billing_technical
  input: "My bill seems wrong and my internet is slow"
  expect:
    completes: true
    # Flexible - could end with either agent
```

### Evaluation Strategy
- **Regular runs**: Include evaluation in your development workflow
- **Regression testing**: Track scores over time to prevent quality degradation
- **A/B testing**: Compare different agent configurations
- **Performance baselines**: Establish minimum acceptable scores for deployment

### Interpreting Results
- **Overall score < 0.5**: Significant issues requiring immediate attention
- **Quality score < 0.7**: Review agent instructions and tool selection
- **Coordination issues**: Check handoff logic and context preservation
- **High handoff counts**: May indicate unclear agent responsibilities

## Troubleshooting

### Common Issues

**No scenarios found**
```ruby
# Ensure scenarios directory exists and contains .yml files
Dir.glob("spec/scenarios/*.yml")  # Should not be empty
```

**Scenarios not loading**
```yaml
# Check YAML syntax - arrays use dashes
expect:
  uses_tools: [tool1, tool2]  # ✓ Correct
  uses_tools: tool1, tool2    # ✗ Invalid YAML
```

**Context preservation false positives**
```ruby
# The framework uses heuristics to detect context loss
# Manual verification may be needed for complex cases
coordination = result.coordination_assessment
puts coordination[:context_issues]  # Check specific issues detected
```

### Performance Considerations
- Evaluation adds ~10-20% overhead to conversation execution
- Large scenario sets (>100) may take several minutes
- Consider running evaluations asynchronously in production monitoring

## Framework Architecture

The evaluation system consists of five core components:

- **Evaluator**: Main orchestrator and scenario runner
- **Scenario**: YAML parsing and expectation management
- **QualityMetrics**: Task completion and agent behavior assessment
- **CoordinationMetrics**: Handoff analysis and pattern detection
- **Reporter**: Output formatting and result presentation

Each component is designed for extensibility while maintaining simple defaults for common use cases.
