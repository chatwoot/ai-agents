# frozen_string_literal: true

require_relative "hash_normalizer"

module Agents
  module Helpers
    module Params
      module_function

      def normalize(params, freeze_result: false)
        HashNormalizer.normalize(params, label: "params", freeze_result: freeze_result)
      end

      def merge(agent_params, runtime_params)
        HashNormalizer.merge(agent_params, runtime_params)
      end
    end
  end
end
