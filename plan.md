# Simplified Agents::Evaluation Framework Plan

## 🎯 **Core Philosophy**
Keep it simple, make it useful. Focus on the 20% of features that deliver 80% of the value.

## 📦 **Minimal Structure**
```
lib/agents/evaluation/
├── evaluation.rb        # Main entry point
├── scenario.rb          # Test scenario definition
├── quality_metrics.rb   # Basic quality assessment
├── coordination_metrics.rb # Handoff analysis
└── reporter.rb          # RSpec-style output + JSON
```

## 🚀 **Dead Simple API**

### **Basic Usage**
```ruby
# Run all scenarios from a directory
results = Agents::Evaluation.run(agent_runner, "spec/scenarios/")

# Or run specific scenarios
results = Agents::Evaluation.run(agent_runner) do |eval|
  eval.scenario "Customer needs billing help" do |s|
    s.input "I was charged twice"
    s.expect_agent "billing"
    s.expect_completion true
  end
end
```

## 📝 **Scenario Format (YAML)**
Keep scenarios simple and readable:

```yaml
# spec/scenarios/billing.yml
- name: double_charge
  input: "I was charged twice this month"
  expect:
    completes: true
    final_agent: billing
    uses_tools: [account_lookup]

- name: vague_complaint
  input: "something's wrong"
  expect:
    completes: false  # OK to not complete
    clarifies: true   # Should ask for details
```

## 📊 **Two Core Metrics Only**

### **1. Quality Metrics** (Did it work?)
```ruby
class QualityMetrics
  def evaluate(result, expectations)
    {
      completed: result.completed? == expectations[:completes],
      correct_agent: result.final_agent == expectations[:final_agent],
      used_expected_tools: (expectations[:uses_tools] - result.tools_used).empty?,
      score: calculate_simple_score
    }
  end
end
```

### **2. Coordination Metrics** (How did agents work together?)
```ruby
class CoordinationMetrics
  def evaluate(conversation)
    handoffs = extract_handoffs(conversation)

    {
      handoff_count: handoffs.count,
      circular_handoffs: detect_circles(handoffs),  # A→B→A
      context_preserved: check_context_continuity(conversation),
      efficiency: handoffs.count <= expected_handoffs
    }
  end
end
```

## 🖥️ **Output Format**

### **Console Output (RSpec-style)**
```bash
$ ruby bin/evaluate

Agents Evaluation

Quality Assessment
  ✓ double_charge (0.8s)
  ✗ vague_complaint (1.2s)
    Expected clarification, got handoff to support
  ✓ upgrade_request (0.6s)

Coordination Analysis
  ⚠ Circular handoff detected: triage → support → triage
  ✓ Context preserved across 5 handoffs

3 scenarios, 2 passed, 1 failed
Coordination: 1 issue found

Results saved to: evaluation_results.json
```

### **JSON Output (Simple & Useful)**
```json
{
  "summary": {
    "total": 3,
    "passed": 2,
    "failed": 1,
    "quality_score": 0.67,
    "coordination_issues": ["circular_handoff"]
  },
  "scenarios": [
    {
      "name": "double_charge",
      "passed": true,
      "duration": 0.8
    },
    {
      "name": "vague_complaint",
      "passed": false,
      "reason": "Expected clarification, got handoff"
    }
  ],
  "insights": [
    "Consider adding clarification logic to triage agent",
    "Review handoff from support back to triage"
  ]
}
```

## 🔧 **Implementation Details**

### **Leverage Existing Callbacks**
```ruby
class Evaluation
  def run_scenario(agent_runner, scenario)
    # Track everything using existing callbacks
    tools_used = []
    handoffs = []

    agent_runner.on_tool_complete { |tool, _| tools_used << tool }
    agent_runner.on_agent_handoff { |from, to, _| handoffs << [from, to] }

    result = agent_runner.run(scenario.input)

    # Simple evaluation
    {
      completed: !result.output.nil?,
      final_agent: extract_final_agent(result.context),
      tools_used: tools_used,
      handoffs: handoffs
    }
  end
end
```

### **Smart Defaults**
- Auto-discover scenario files in `spec/scenarios/`
- Infer expectations from scenario names when not specified
- Provide sensible pass/fail criteria out of the box

### **Progressive Enhancement**
Start simple, add features as needed:
```ruby
# Phase 1: Basic implementation (this plan)
Agents::Evaluation.run(runner, "spec/scenarios/")

# Phase 2: Custom expectations (if needed later)
eval.expect_custom { |result| result.output.include?("resolved") }

# Phase 3: Performance metrics (if needed later)
eval.measure_performance { latency < 2.seconds }
```

## 📋 **What We're NOT Building**
- Complex trajectory analysis
- Self-evaluating agents
- Multi-dimensional scoring algorithms
- Real-time streaming updates
- Counterfactual analysis

## 🎯 **What We ARE Building**
- Simple scenario runner
- Basic quality checks (did it complete? right agent? right tools?)
- Coordination analysis (circular handoffs, context preservation)
- RSpec-style output for developers
- JSON output for CI/CD
- Zero configuration required

## 🚦 **Success Criteria**
A developer can:
1. Write a scenario in 3 lines of YAML
2. Run evaluation with one command
3. Get actionable feedback immediately
4. Integrate with CI/CD via JSON output

This simplified approach takes the best ideas (event-driven monitoring, scenario-based testing, coordination analysis) but packages them in a way that's easy to implement and immediately useful.
