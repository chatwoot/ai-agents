# frozen_string_literal: true

require_relative "hash_normalizer"

module Agents
  module Helpers
    module Headers
      module_function

      def normalize(headers, freeze_result: false)
        HashNormalizer.normalize(headers, label: "headers", freeze_result: freeze_result)
      end

      def merge(agent_headers, runtime_headers)
        HashNormalizer.merge(agent_headers, runtime_headers)
      end
    end
  end
end
