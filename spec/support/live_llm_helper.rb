# frozen_string_literal: true

# Helper utilities for running live LLM integration specs.
# These specs are tagged :live_llm and only run when explicitly enabled.
module LiveLLMHelper
  DEFAULT_LIVE_MODELS = {
    "openai" => "gpt-5-mini",
    "anthropic" => "claude-haiku-4-5",
    "gemini" => "gemini-1.5-flash"
  }.freeze

  def configure_live_llm(model: live_model)
    provider = live_llm_provider
    Agents.configure do |config|
      apply_provider_key(config, provider)
      config.default_model = model
      config.request_timeout = Integer(ENV.fetch("LIVE_LLM_REQUEST_TIMEOUT", 30))
      config.debug = false
    end
  end

  def live_model
    provider = live_llm_provider
    ENV.fetch(live_model_env_key(provider), DEFAULT_LIVE_MODELS.fetch(provider, DEFAULT_LIVE_MODELS["openai"]))
  end

  def live_llm_provider
    ENV.fetch("LIVE_LLM_PROVIDER", "openai").downcase
  end

  private

  def apply_provider_key(config, provider)
    case provider
    when "openai"
      config.openai_api_key = ENV["OPENAI_API_KEY"]
    when "anthropic"
      config.anthropic_api_key = ENV["ANTHROPIC_API_KEY"]
    when "gemini"
      config.gemini_api_key = ENV["GEMINI_API_KEY"]
    else
      raise ArgumentError, "Unsupported LIVE_LLM_PROVIDER: #{provider}"
    end
  end

  def live_model_env_key(provider)
    case provider
    when "openai"
      "OPENAI_MODEL"
    when "anthropic"
      "ANTHROPIC_MODEL"
    when "gemini"
      "GEMINI_MODEL"
    else
      "OPENAI_MODEL"
    end
  end
end
