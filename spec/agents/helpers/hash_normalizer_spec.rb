# frozen_string_literal: true

require "spec_helper"

RSpec.describe Agents::Helpers::HashNormalizer do
  describe ".normalize" do
    context "with nil input" do
      it "returns empty hash" do
        expect(described_class.normalize(nil, label: "test")).to eq({})
      end

      it "returns frozen empty hash when freeze_result is true" do
        result = described_class.normalize(nil, label: "test", freeze_result: true)

        expect(result).to eq({})
        expect(result).to be_frozen
      end
    end

    context "with empty hash" do
      it "returns empty hash" do
        expect(described_class.normalize({}, label: "test")).to eq({})
      end

      it "returns frozen empty hash when freeze_result is true" do
        result = described_class.normalize({}, label: "test", freeze_result: true)

        expect(result).to eq({})
        expect(result).to be_frozen
      end
    end

    context "with string keys" do
      it "symbolizes keys" do
        result = described_class.normalize({ "foo" => 1, "bar" => 2 }, label: "test")

        expect(result).to eq({ foo: 1, bar: 2 })
      end

      it "returns a new hash object" do
        input = { "foo" => 1 }
        result = described_class.normalize(input, label: "test")

        expect(result).not_to be(input)
      end

      it "does not mutate the input hash" do
        input = { "foo" => 1 }
        described_class.normalize(input, label: "test")

        expect(input).to eq({ "foo" => 1 })
      end
    end

    context "with symbol keys" do
      it "preserves symbol keys" do
        result = described_class.normalize({ foo: 1, bar: 2 }, label: "test")

        expect(result).to eq({ foo: 1, bar: 2 })
      end
    end

    context "with mixed keys" do
      it "symbolizes all keys" do
        result = described_class.normalize({ foo: 1, "bar" => 2 }, label: "test")

        expect(result).to eq({ foo: 1, bar: 2 })
      end
    end

    context "with freeze_result option" do
      it "freezes the result when true" do
        result = described_class.normalize({ foo: 1 }, label: "test", freeze_result: true)

        expect(result).to be_frozen
      end

      it "does not freeze when false" do
        result = described_class.normalize({ foo: 1 }, label: "test", freeze_result: false)

        expect(result).not_to be_frozen
      end

      it "does not freeze by default" do
        result = described_class.normalize({ foo: 1 }, label: "test")

        expect(result).not_to be_frozen
      end
    end

    context "with objects responding to to_h" do
      it "converts to hash and symbolizes keys" do
        obj = double("hash_like", to_h: { "foo" => 1 }, empty?: false)
        result = described_class.normalize(obj, label: "test")

        expect(result).to eq({ foo: 1 })
      end
    end

    context "with empty-responding objects" do
      it "returns empty hash for empty string" do
        expect(described_class.normalize("", label: "test")).to eq({})
      end

      it "returns empty hash for empty array" do
        expect(described_class.normalize([], label: "test")).to eq({})
      end
    end

    context "with invalid input" do
      it "includes label in the error message" do
        expect do
          described_class.normalize("not_empty", label: "custom_label")
        end.to raise_error(ArgumentError, "custom_label must be a Hash or respond to #to_h")
      end

      it "raises ArgumentError for non-hash non-to_h objects" do
        expect do
          described_class.normalize(42, label: "test")
        end.to raise_error(ArgumentError, "test must be a Hash or respond to #to_h")
      end

      it "raises TypeError for arrays without valid pairs" do
        expect do
          described_class.normalize([1, 2, 3], label: "test")
        end.to raise_error(TypeError)
      end
    end
  end

  describe ".merge" do
    context "when both are empty" do
      it "returns empty hash" do
        expect(described_class.merge({}, {})).to eq({})
      end
    end

    context "when base is empty" do
      it "returns override" do
        override = { foo: 1 }

        expect(described_class.merge({}, override)).to eq(override)
      end

      it "returns the same override object" do
        override = { foo: 1 }

        expect(described_class.merge({}, override)).to be(override)
      end
    end

    context "when override is empty" do
      it "returns base" do
        base = { foo: 1 }

        expect(described_class.merge(base, {})).to eq(base)
      end

      it "returns the same base object" do
        base = { foo: 1 }

        expect(described_class.merge(base, {})).to be(base)
      end
    end

    context "with disjoint keys" do
      it "merges both hashes" do
        result = described_class.merge({ a: 1 }, { b: 2 })

        expect(result).to eq({ a: 1, b: 2 })
      end
    end

    context "with overlapping keys" do
      it "gives precedence to override" do
        result = described_class.merge({ a: 1, b: 2 }, { b: 99, c: 3 })

        expect(result).to eq({ a: 1, b: 99, c: 3 })
      end
    end

    context "with input mutation safety" do
      it "does not mutate the base hash" do
        base = { a: 1 }
        described_class.merge(base, { b: 2 })

        expect(base).to eq({ a: 1 })
      end

      it "does not mutate the override hash" do
        override = { b: 2 }
        described_class.merge({ a: 1 }, override)

        expect(override).to eq({ b: 2 })
      end
    end
  end
end
