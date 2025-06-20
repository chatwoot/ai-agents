# frozen_string_literal: true

require_relative "lib/agents/version"

Gem::Specification.new do |spec|
  spec.name = "ruby-agents"
  spec.version = Agents::VERSION
  spec.authors = ["Ruby Agents Team"]
  spec.email = ["contact@ruby-agents.com"]

  spec.summary = "Production-ready multi-agent AI workflows for Ruby"
  spec.description = "Ruby Agents SDK provides a robust framework for building complex AI workflows with multi-agent orchestration, tool execution, intelligent handoffs, and provider-agnostic LLM integration. Built for production use with comprehensive error handling, tracing, and guardrails."
  spec.homepage = "https://github.com/ruby-agents/ruby-agents"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/ruby-agents/ruby-agents"
  spec.metadata["changelog_uri"] = "https://github.com/ruby-agents/ruby-agents/blob/main/CHANGELOG.md"
  spec.metadata["documentation_uri"] = "https://ruby-agents.github.io/ruby-agents"
  spec.metadata["bug_tracker_uri"] = "https://github.com/ruby-agents/ruby-agents/issues"

  # Include only essential files
  spec.files = Dir[
    "lib/**/*.rb",
    "README.md",
    "LICENSE.txt",
    "CHANGELOG.md"
  ]
  
  spec.require_paths = ["lib"]

  # Core dependencies - minimal and production-ready
  spec.add_dependency "faraday", "~> 2.0"
  spec.add_dependency "faraday-retry", "~> 2.0"
  spec.add_dependency "json", "~> 2.6"

  # Development dependencies
  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rubocop", "~> 1.50"

  spec.post_install_message = <<~MSG
    Thank you for installing Ruby Agents SDK!
    
    Get started: https://ruby-agents.github.io/ruby-agents/getting-started
    Examples: https://github.com/ruby-agents/ruby-agents/tree/main/examples
  MSG
end
