# frozen_string_literal: true

module Agents
  module Helpers
    module NameNormalizer
      module_function

      def to_tool_name(name)
        name.downcase.gsub(/\s+/, "_").gsub(/[^a-z0-9_]/, "")
      end
    end
  end
end
