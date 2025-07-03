# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"
require "rubocop/rake_task"

# Test tasks
RSpec::Core::RakeTask.new(:spec) do |task|
  task.pattern = "spec/**/*_spec.rb"
  task.rspec_opts = "--format documentation --color"
end

# Linting tasks
RuboCop::RakeTask.new(:rubocop) do |task|
  task.options = ["--display-cop-names"]
end

# Integration test tasks
namespace :test do
  desc "Run integration tests"
  task :integration do
    Dir.glob("test/integration/*_test.rb").each do |file|
      puts "Running #{file}..."
      system("ruby #{file}") || exit(1)
    end
  end

  desc "Run all tests (unit + integration)"
  task all: %i[spec integration]
end

# Development tasks
namespace :dev do
  desc "Run console with library loaded"
  task :console do
    exec "irb -r ./lib/agents"
  end

  desc "Check syntax of all Ruby files"
  task :syntax do
    Dir.glob("**/*.rb").each do |file|
      next if file.start_with?("vendor/")

      puts "Checking #{file}..."
      system("ruby -c #{file}") || exit(1)
    end
    puts "All files have valid syntax!"
  end
end

# Documentation tasks
namespace :doc do
  desc "Generate YARD documentation"
  task :generate do
    system("yard doc") || exit(1)
  end

  desc "Serve documentation locally"
  task :serve do
    system("yard server --reload")
  end
end

# Default task runs basic checks
task default: %i[dev:syntax spec rubocop]

# Full CI task
task ci: %i[dev:syntax spec rubocop test:integration]
