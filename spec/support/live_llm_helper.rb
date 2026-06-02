# frozen_string_literal: true

# Helper utilities for running live LLM integration specs.
# These specs are tagged :live_llm and only run when explicitly enabled.
# Requests route through OpenRouter; the namespaced model id (e.g. "openai/gpt-4.1-nano")
# resolves uniquely to RubyLLM's :openrouter provider in the model registry.
module LiveLLMHelper
  DEFAULT_LIVE_MODEL = "openai/gpt-4.1-nano"

  def configure_live_llm(model: live_model)
    Agents.configure do |config|
      config.openrouter_api_key = ENV["OPENROUTER_API_KEY"]
      config.default_model = model
      config.request_timeout = Integer(ENV.fetch("OPENROUTER_REQUEST_TIMEOUT", 30))
      config.debug = false
    end
  end

  def live_model
    ENV.fetch("OPENROUTER_MODEL", DEFAULT_LIVE_MODEL)
  end

  def live_provider
    :openrouter
  end
end
