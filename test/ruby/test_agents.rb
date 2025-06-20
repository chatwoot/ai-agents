# frozen_string_literal: true

require "test_helper"

class TestAgents < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::Agents::VERSION
  end

  def test_provider_registry_loads
    assert Agents::Providers::Registry.registered?(:openai)
    assert Agents::Providers::Registry.registered?(:anthropic)
  end

  def test_configuration_has_defaults
    config = Agents::Configuration.new
    assert_equal :openai, config.default_provider
    assert_equal "gpt-4.1-mini", config.default_model
  end
end
