# frozen_string_literal: true

require "simplecov"

SimpleCov.start do
  add_filter "/spec/"
  add_filter "/examples/"
  add_filter "/bin/"
  add_filter "/sig/"

  add_group "Core", "lib/agents.rb"
  add_group "Agents", "lib/agents/"

  minimum_coverage 50
  minimum_coverage_by_file 40
end

require_relative "../lib/agents"

# Load support files
Dir[File.join(__dir__, "support", "**", "*.rb")].each { |f| require f }

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
end
