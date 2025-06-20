# frozen_string_literal: true

module Agents
  module Guardrails
    # Simple guardrails implementation for the knowledge hub
    class SimpleGuardrails
      class << self
        # Check input guardrails for an agent
        def check_input(agent_class, message, context = {})
          return { allowed: true } unless agent_class.respond_to?(:input_guardrail)
          
          begin
            result = agent_class.input_guardrail(message, context)
            result.is_a?(Hash) ? result : { allowed: true }
          rescue => e
            puts "⚠️  Input guardrail error: #{e.message}" if ENV['DEBUG']
            { allowed: true } # Default to allow on error
          end
        end

        # Check output guardrails for an agent
        def check_output(agent_class, response, context = {})
          return { allowed: true, enhanced_response: response } unless agent_class.respond_to?(:output_guardrail)
          
          begin
            result = agent_class.output_guardrail(response, context)
            if result.is_a?(Hash)
              result[:enhanced_response] ||= response
              result
            else
              { allowed: true, enhanced_response: response }
            end
          rescue => e
            puts "⚠️  Output guardrail error: #{e.message}" if ENV['DEBUG']
            { allowed: true, enhanced_response: response } # Default to allow on error
          end
        end

        # Apply guardrails to agent processing
        def apply_to_agent_call(agent, message, context = {})
          agent_class = agent.class
          
          # Check input guardrails
          input_check = check_input(agent_class, message, context)
          
          unless input_check[:allowed]
            return create_guardrail_response(input_check, :input)
          end

          # Process normally (this would be called by the agent system)
          # For now, we'll just return success to indicate guardrails passed
          { allowed: true, proceed: true }
        end

        # Apply output guardrails and enhance response
        def enhance_response(agent_class, response, context = {})
          output_check = check_output(agent_class, response, context)
          
          if output_check[:allowed]
            output_check[:enhanced_response] || response
          else
            create_guardrail_response(output_check, :output)
          end
        end

        private

        def create_guardrail_response(check_result, type)
          prefix = type == :input ? "🛡️ Input Filtered:" : "🛡️ Output Filtered:"
          
          response = "#{prefix} #{check_result[:reason]}"
          
          if check_result[:suggested_rephrase]
            response += "\n\n💡 Suggestion: #{check_result[:suggested_rephrase]}"
          end

          if check_result[:enhanced_response]
            response = check_result[:enhanced_response]
          end

          response
        end
      end
    end
  end
end