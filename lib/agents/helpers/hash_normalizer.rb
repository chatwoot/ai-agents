# frozen_string_literal: true

module Agents
  module Helpers
    module HashNormalizer
      module_function

      # NOTE: freeze_result performs a shallow freeze on the top-level hash only.
      # Nested values remain mutable — e.g. hash[:nested][:key] = "x" would succeed.
      def normalize(input, label:, freeze_result: false)
        return freeze_result ? {}.freeze : {} if input.nil? || (input.respond_to?(:empty?) && input.empty?)

        hash = input.respond_to?(:to_h) ? input.to_h : input
        raise ArgumentError, "#{label} must be a Hash or respond to #to_h" unless hash.is_a?(Hash)

        result = hash.transform_keys { |key| key.is_a?(Symbol) ? key : key.to_sym }
        freeze_result ? result.freeze : result
      end

      def merge(base, override)
        return override if base.empty?
        return base if override.empty?

        base.merge(override)
      end
    end
  end
end
