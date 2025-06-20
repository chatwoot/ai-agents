# frozen_string_literal: true

module Agents
  module Guardrails
    # Simple guardrails manager for input/output validation
    class Manager
      def initialize
        @guardrails = []
      end

      # Add a guardrail
      def add_guardrail(guardrail)
        @guardrails << guardrail
      end

      # Check content against all guardrails
      def check(content, context = {})
        @guardrails.each do |guardrail|
          result = guardrail.validate(content, context)
          unless result[:valid]
            raise ValidationError, result[:message]
          end
        end
        true
      end
    end

    # Base guardrail class
    class BaseGuardrail
      def initialize(config = {})
        @config = config
      end

      def validate(content, context = {})
        { valid: true, message: nil }
      end
    end

    # Content length guardrail
    class LengthGuardrail < BaseGuardrail
      def validate(content, context = {})
        return { valid: true } unless content.is_a?(String)

        if @config[:max_length] && content.length > @config[:max_length]
          return { valid: false, message: "Content too long (#{content.length} > #{@config[:max_length]})" }
        end

        if @config[:min_length] && content.length < @config[:min_length]
          return { valid: false, message: "Content too short (#{content.length} < #{@config[:min_length]})" }
        end

        { valid: true }
      end
    end

    # Forbidden patterns guardrail
    class PatternGuardrail < BaseGuardrail
      def validate(content, context = {})
        return { valid: true } unless content.is_a?(String)

        if @config[:forbidden_patterns]
          @config[:forbidden_patterns].each do |pattern|
            if content.downcase.include?(pattern.downcase)
              return { valid: false, message: "Content contains forbidden pattern: #{pattern}" }
            end
          end
        end

        { valid: true }
      end
    end

    class ValidationError < Error; end
  end
end
