# frozen_string_literal: true

require "spec_helper"

RSpec.describe Agents::Helpers::Params do
  describe ".normalize" do
    context "with nil input" do
      it "returns empty hash" do
        expect(described_class.normalize(nil)).to eq({})
      end

      it "returns frozen empty hash when freeze_result is true" do
        result = described_class.normalize(nil, freeze_result: true)

        expect(result).to eq({})
        expect(result).to be_frozen
      end
    end

    context "with empty hash" do
      it "returns empty hash" do
        expect(described_class.normalize({})).to eq({})
      end
    end

    context "with string keys" do
      it "symbolizes keys" do
        result = described_class.normalize({ "max_tokens" => 100, "temperature" => 0.5 })

        expect(result).to eq({ max_tokens: 100, temperature: 0.5 })
      end
    end

    context "with symbol keys" do
      it "preserves symbol keys" do
        result = described_class.normalize({ max_tokens: 100 })

        expect(result).to eq({ max_tokens: 100 })
      end
    end

    context "with freeze_result option" do
      it "freezes the result when true" do
        result = described_class.normalize({ max_tokens: 100 }, freeze_result: true)

        expect(result).to be_frozen
      end

      it "does not freeze by default" do
        result = described_class.normalize({ max_tokens: 100 })

        expect(result).not_to be_frozen
      end
    end

    context "with invalid input" do
      it "raises ArgumentError mentioning params" do
        expect do
          described_class.normalize("invalid")
        end.to raise_error(ArgumentError, "params must be a Hash or respond to #to_h")
      end
    end
  end

  describe ".merge" do
    context "when agent_params is empty" do
      it "returns runtime_params" do
        runtime_params = { max_tokens: 100 }

        expect(described_class.merge({}, runtime_params)).to eq(runtime_params)
      end
    end

    context "when runtime_params is empty" do
      it "returns agent_params" do
        agent_params = { temperature: 0.5 }

        expect(described_class.merge(agent_params, {})).to eq(agent_params)
      end
    end

    context "with overlapping keys" do
      it "gives precedence to runtime_params" do
        agent_params = { max_tokens: 100, temperature: 0.5 }
        runtime_params = { max_tokens: 200, top_p: 0.9 }
        result = described_class.merge(agent_params, runtime_params)

        expect(result).to eq({ max_tokens: 200, temperature: 0.5, top_p: 0.9 })
      end
    end
  end
end
