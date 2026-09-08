# frozen_string_literal: true

RSpec.describe Agents do
  describe ".configuration" do
    it "shares RubyLLM's configuration" do
      expect(described_class.configuration).to be(RubyLLM.config)
    end
  end

  describe ".configure" do
    around do |example|
      original = RubyLLM.config.dup
      example.run
    ensure
      RubyLLM.instance_variable_set(:@config, original)
    end

    it "configures native provider options without an SDK allowlist" do
      result = described_class.configure do |config|
        config.anthropic_api_key = "test-key"
        config.log_level = :debug
      end

      expect(result).to be(RubyLLM.config)
      expect(RubyLLM.config.anthropic_api_key).to eq("test-key")
      expect(RubyLLM.config.log_level).to eq(:debug)
    end

    it "preserves settings configured directly through RubyLLM" do
      RubyLLM.configure { |config| config.request_timeout = 42 }
      described_class.configure { |config| config.openai_api_key = "test-key" }

      expect(RubyLLM.config.request_timeout).to eq(42)
    end

    it "returns the configuration without a block" do
      expect(described_class.configure).to be(RubyLLM.config)
    end
  end
end
