# frozen_string_literal: true

# Guardrail system - provides safety boundaries for agent inputs and outputs
# Guardrails act as validation gates that can inspect and potentially block agent interactions
# based on custom logic. Input guardrails validate user messages before processing, while output
# guardrails check agent responses before returning them. This design ensures safety and compliance
# without coupling validation logic to individual agents, allowing guardrails to be shared and
# composed across different agent implementations for consistent behavior enforcement.

module Agents
  class GuardrailViolation < Agents::Error
    attr_reader :guardrail_name, :output_info

    def initialize(message, guardrail_name: nil, output_info: nil)
      super(message)
      @guardrail_name = guardrail_name
      @output_info = output_info
    end
  end

  class GuardrailFunctionOutput
    attr_reader :output_info, :tripwire_triggered

    def initialize(output_info: nil, tripwire_triggered: false)
      @output_info = output_info
      @tripwire_triggered = tripwire_triggered
    end

    def triggered?
      @tripwire_triggered
    end
  end

  class InputGuardrailResult
    attr_reader :guardrail, :output

    def initialize(guardrail:, output:)
      @guardrail = guardrail
      @output = output
    end

    def triggered?
      @output.triggered?
    end
  end

  class OutputGuardrailResult
    attr_reader :guardrail, :agent_output, :agent, :output

    def initialize(guardrail:, agent_output:, agent:, output:)
      @guardrail = guardrail
      @agent_output = agent_output
      @agent = agent
      @output = output
    end

    def triggered?
      @output.triggered?
    end
  end

  class InputGuardrail
    attr_accessor :name

    def initialize(name: nil, &block)
      @name = name
      @guardrail_function = block
      raise ArgumentError, "Block required for guardrail" unless @guardrail_function
    end

    def call(context, agent, input)
      output = @guardrail_function.call(context, agent, input)

      InputGuardrailResult.new(
        guardrail: self,
        output: output
      )
    end

    private

    attr_reader :guardrail_function
  end

  class OutputGuardrail
    attr_accessor :name

    def initialize(name: nil, &block)
      @name = name
      @guardrail_function = block
      raise ArgumentError, "Block required for guardrail" unless @guardrail_function
    end

    def call(context, agent, agent_output)
      output = @guardrail_function.call(context, agent, agent_output)

      OutputGuardrailResult.new(
        guardrail: self,
        agent: agent,
        agent_output: agent_output,
        output: output
      )
    end

    private

    attr_reader :guardrail_function
  end
end
