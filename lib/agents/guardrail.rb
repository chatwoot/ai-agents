# frozen_string_literal: true

# = Guardrail System
#
# Provides safety boundaries for agent inputs and outputs through declarative guardrail classes.
# Guardrails act as validation gates that can inspect and potentially block agent interactions
# based on custom logic.
#
# == Overview
#
# * Input guardrails validate user messages before processing
# * Output guardrails check agent responses before returning them
# * Guardrails use internal agents to perform validation
# * Pattern matching determines if a guardrail should trigger
#
# == Usage Examples
#
# === Creating an Input Guardrail
#
#   class ProfanityGuardrail < Agents::InputGuardrail
#     name "Profanity Filter"
#     model "gpt-4o-mini"
#     instructions <<~INSTRUCTIONS
#       Analyze the text for inappropriate language.
#       Respond with:
#       - "CLEAN: [reasoning]" if appropriate
#       - "INAPPROPRIATE: [reasoning]" if inappropriate
#     INSTRUCTIONS
#
#     trigger_on /^INAPPROPRIATE:/
#     trigger_message { |reason| "Please use appropriate language. #{reason}" }
#   end
#
# === Creating an Output Guardrail
#
#   class ConfidentialityGuardrail < Agents::OutputGuardrail
#     name "Confidentiality Check"
#     model "gpt-4o-mini"
#     instructions "Check if response contains confidential information..."
#
#     trigger_on /^CONFIDENTIAL:/
#     trigger_message "Response contained confidential information"
#   end
#
# === Using Guardrails with Agents
#
#   class CustomerServiceAgent < Agents::Agent
#     name "Customer Service"
#     instructions "Help customers with their requests"
#
#     input_guardrails ProfanityGuardrail, SpamGuardrail
#     output_guardrails ConfidentialityGuardrail
#   end

module Agents
  # Raised when a guardrail violation occurs during agent processing
  class GuardrailViolation < Agents::Error
    # The name of the guardrail that was violated
    attr_reader :guardrail_name

    # Additional information about the violation
    attr_reader :output_info

    # Creates a new guardrail violation error
    #
    # @param message [String] The error message
    # @param guardrail_name [String, nil] The name of the guardrail that was violated
    # @param output_info [String, nil] Additional information about the violation
    def initialize(message, guardrail_name: nil, output_info: nil)
      super(message)
      @guardrail_name = guardrail_name
      @output_info = output_info
    end
  end

  # Represents the output from a guardrail evaluation
  class GuardrailFunctionOutput
    # Information about the guardrail evaluation result
    attr_reader :output_info

    # Whether the guardrail was triggered (violation detected)
    attr_reader :tripwire_triggered

    # Creates a new guardrail function output
    #
    # @param output_info [String, nil] Information about the evaluation
    # @param tripwire_triggered [Boolean] Whether the guardrail was triggered
    def initialize(output_info: nil, tripwire_triggered: false)
      @output_info = output_info
      @tripwire_triggered = tripwire_triggered
    end

    # Checks if the guardrail was triggered
    #
    # @return [Boolean] true if the guardrail detected a violation
    def triggered?
      @tripwire_triggered
    end
  end

  # Result from evaluating an input guardrail
  class InputGuardrailResult
    # The guardrail that was evaluated
    attr_reader :guardrail

    # The output from the guardrail evaluation
    attr_reader :output

    # Creates a new input guardrail result
    #
    # @param guardrail [InputGuardrail] The guardrail that was evaluated
    # @param output [GuardrailFunctionOutput] The evaluation output
    def initialize(guardrail:, output:)
      @guardrail = guardrail
      @output = output
    end

    # Checks if the guardrail was triggered
    #
    # @return [Boolean] true if the guardrail detected a violation
    def triggered?
      @output.triggered?
    end
  end

  # Result from evaluating an output guardrail
  class OutputGuardrailResult
    # The guardrail that was evaluated
    attr_reader :guardrail

    # The agent output that was evaluated
    attr_reader :agent_output

    # The agent that produced the output
    attr_reader :agent

    # The output from the guardrail evaluation
    attr_reader :output

    # Creates a new output guardrail result
    #
    # @param guardrail [OutputGuardrail] The guardrail that was evaluated
    # @param agent_output [String] The agent output being evaluated
    # @param agent [Agent] The agent that produced the output
    # @param output [GuardrailFunctionOutput] The evaluation output
    def initialize(guardrail:, agent_output:, agent:, output:)
      @guardrail = guardrail
      @agent_output = agent_output
      @agent = agent
      @output = output
    end

    # Checks if the guardrail was triggered
    #
    # @return [Boolean] true if the guardrail detected a violation
    def triggered?
      @output.triggered?
    end
  end

  # Provides DSL methods for defining guardrails declaratively
  module GuardrailDefinition
    def self.included(base)
      base.extend(ClassMethods)
    end

    # Class methods added to guardrail classes
    module ClassMethods
      attr_reader :guardrail_name, :guardrail_model, :guardrail_provider,
                  :guardrail_instructions, :trigger_pattern, :trigger_message_proc

      # Sets the name of the guardrail
      #
      # @param value [String] The guardrail name
      # @example
      #   name "Profanity Filter"
      def name(value)
        @guardrail_name = value
      end

      # Sets the model to use for the internal agent
      #
      # @param value [String] The model identifier
      # @example
      #   model "gpt-4o-mini"
      def model(value)
        @guardrail_model = value
      end

      # Sets the provider for the internal agent
      #
      # @param value [Symbol] The provider (:openai, :anthropic, etc.)
      # @example
      #   provider :anthropic
      def provider(value)
        @guardrail_provider = value
      end

      # Sets the instructions for the internal agent
      #
      # @param text [String] The instructions text
      # @example
      #   instructions "Analyze the text for inappropriate content..."
      def instructions(text)
        @guardrail_instructions = text
      end

      # Sets the pattern to match for triggering the guardrail
      #
      # TODO: Replace this with structured output implementation
      # Ref: https://github.com/danielfriis/ruby_llm-schema
      #      https://github.com/crmne/ruby_llm/issues/11
      # @param pattern [Regexp] The pattern to match in agent responses
      # @example
      #   trigger_on /^INAPPROPRIATE:/
      def trigger_on(pattern)
        @trigger_pattern = pattern
      end

      # Sets the message to return when the guardrail is triggered
      #
      # @param msg [String, nil] Static message to return
      # @yield [reason] Block that generates the message dynamically
      # @yieldparam reason [String] The reason extracted from the pattern match
      # @example Static message
      #   trigger_message "Content violated our policies"
      # @example Dynamic message
      #   trigger_message { |reason| "Violation detected: #{reason}" }
      def trigger_message(msg = nil, &block)
        @trigger_message_proc = block_given? ? block : ->(_) { msg }
      end
    end

    # Gets the guardrail name
    #
    # @return [String] The guardrail name
    def name
      self.class.guardrail_name
    end

    private

    # Creates the internal agent used for validation
    #
    # @return [Agent] A new agent instance configured with guardrail settings
    def create_internal_agent
      guardrail_class = self.class

      Class.new(Agent) do
        name guardrail_class.guardrail_name
        model guardrail_class.guardrail_model
        provider guardrail_class.guardrail_provider if guardrail_class.guardrail_provider
        instructions guardrail_class.guardrail_instructions
      end.new
    end

    # Processes the agent response to determine if guardrail should trigger
    #
    # @param response [AgentResponse] The response from the internal agent
    # @return [GuardrailFunctionOutput] The processed guardrail output
    def process_response(response)
      pattern = self.class.trigger_pattern
      message_proc = self.class.trigger_message_proc

      if pattern && response.content.match?(pattern)
        reason = response.content.sub(pattern, "").strip
        output_info = message_proc ? message_proc.call(reason) : reason

        GuardrailFunctionOutput.new(
          output_info: output_info,
          tripwire_triggered: true
        )
      else
        GuardrailFunctionOutput.new(
          output_info: response.content,
          tripwire_triggered: false
        )
      end
    end
  end

  # Base class for input guardrails that validate user messages before processing
  #
  # @example
  #   class SpamGuardrail < Agents::InputGuardrail
  #     name "Spam Filter"
  #     model "gpt-4o-mini"
  #     instructions "Detect if the message is spam..."
  #     trigger_on /^SPAM:/
  #     trigger_message "Your message was flagged as spam"
  #   end
  class InputGuardrail
    include GuardrailDefinition

    # Creates a new input guardrail instance
    def initialize
      @internal_agent = create_internal_agent
    end

    # Evaluates the input against this guardrail
    #
    # @param context [Context] The current context
    # @param agent [Agent] The agent that will process the input
    # @param input [String] The user input to validate
    # @return [InputGuardrailResult] The result of the evaluation
    def call(context, _agent, input)
      response = @internal_agent.call(input.to_s, context: context)
      output = process_response(response)

      InputGuardrailResult.new(
        guardrail: self,
        output: output
      )
    end
  end

  # Base class for output guardrails that validate agent responses before returning them
  #
  # @example
  #   class ToxicityGuardrail < Agents::OutputGuardrail
  #     name "Toxicity Filter"
  #     model "gpt-4o-mini"
  #     instructions "Check if the response contains toxic content..."
  #     trigger_on /^TOXIC:/
  #     trigger_message { |reason| "Response filtered: #{reason}" }
  #   end
  class OutputGuardrail
    include GuardrailDefinition

    # Creates a new output guardrail instance
    def initialize
      @internal_agent = create_internal_agent
    end

    # Evaluates the agent output against this guardrail
    #
    # @param context [Context] The current context
    # @param agent [Agent] The agent that produced the output
    # @param agent_output [String] The agent output to validate
    # @return [OutputGuardrailResult] The result of the evaluation
    def call(context, agent, agent_output)
      response = @internal_agent.call(agent_output.to_s, context: context)
      output = process_response(response)

      OutputGuardrailResult.new(
        guardrail: self,
        agent: agent,
        agent_output: agent_output,
        output: output
      )
    end
  end
end
