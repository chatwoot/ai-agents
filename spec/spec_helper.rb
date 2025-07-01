# frozen_string_literal: true

require "bundler/setup"

# Load the gem
require "agents"

# Configure RSpec
RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on Module and main
  config.disable_monkey_patching!

  # Use expect syntax only
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # Capture warnings
  config.warnings = false

  # Clean up after each test
  config.after do
    # Reset configuration to avoid test pollution
    Agents.reset_configuration! if Agents.respond_to?(:reset_configuration!)
  end
end
