# frozen_string_literal: true

module Agents
  module Helpers
    module Params
      module_function

      def normalize(params, freeze_result: false)
        return freeze_result ? {}.freeze : {} if params.nil? || (params.respond_to?(:empty?) && params.empty?)

        hash = params.respond_to?(:to_h) ? params.to_h : params
        raise ArgumentError, "params must be a Hash or respond to #to_h" unless hash.is_a?(Hash)

        result = symbolize_keys(hash)
        freeze_result ? result.freeze : result
      end

      def merge(agent_params, runtime_params)
        return runtime_params if agent_params.empty?
        return agent_params if runtime_params.empty?

        agent_params.merge(runtime_params) { |_key, _agent_value, runtime_value| runtime_value }
      end

      def symbolize_keys(hash)
        hash.transform_keys do |key|
          key.is_a?(Symbol) ? key : key.to_sym
        end
      end
      private_class_method :symbolize_keys
    end
  end
end
