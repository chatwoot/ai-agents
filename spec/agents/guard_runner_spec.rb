# frozen_string_literal: true

require_relative "../../lib/agents"

RSpec.describe Agents::GuardRunner do
  let(:callback_manager) { instance_double(Agents::CallbackManager) }
  let(:context_wrapper) do
    instance_double(Agents::RunContext, callback_manager: callback_manager, context: {})
  end

  before do
    allow(callback_manager).to receive(:emit_guard_triggered)
  end

  def build_guard(name: "test_guard", &block)
    guard_class = Class.new(Agents::Guard) do
      guard_name name
      define_method(:call, &block)
    end
    guard_class.new
  end

  describe ".run" do
    context "with no guards" do
      it "returns a passing result with original content" do
        result = described_class.run([], "hello", context_wrapper, phase: :input)
        expect(result.pass?).to be true
        expect(result.content).to eq("hello")
      end
    end

    context "with a single passing guard" do
      it "returns a passing result" do
        guard = build_guard { |_content, _ctx| nil }
        result = described_class.run([guard], "hello", context_wrapper, phase: :input)
        expect(result.pass?).to be true
        expect(result.content).to eq("hello")
      end

      it "does not emit a callback" do
        guard = build_guard { |_content, _ctx| nil }
        described_class.run([guard], "hello", context_wrapper, phase: :input)
        expect(callback_manager).not_to have_received(:emit_guard_triggered)
      end
    end

    context "with a guard that returns GuardResult.pass" do
      it "treats explicit pass the same as nil" do
        guard = build_guard { |_content, _ctx| Agents::GuardResult.pass }
        result = described_class.run([guard], "hello", context_wrapper, phase: :input)
        expect(result.pass?).to be true
        expect(callback_manager).not_to have_received(:emit_guard_triggered)
      end
    end

    context "with a single rewriting guard" do
      it "returns result with rewritten content" do
        guard = build_guard { |content, _ctx| Agents::GuardResult.rewrite(content.upcase) }
        result = described_class.run([guard], "hello", context_wrapper, phase: :output)
        expect(result.content).to eq("HELLO")
      end

      it "emits a callback" do
        guard = build_guard(name: "uppercaser") do |content, _ctx|
          Agents::GuardResult.rewrite(content.upcase, message: "uppercased")
        end
        described_class.run([guard], "hello", context_wrapper, phase: :output)
        expect(callback_manager).to have_received(:emit_guard_triggered)
          .with("uppercaser", :output, :rewrite, "uppercased", context_wrapper)
      end
    end

    context "with a tripwire guard" do
      it "raises Guard::Tripwire with correct metadata" do
        guard = build_guard(name: "blocker") do |_content, _ctx|
          Agents::GuardResult.tripwire(message: "blocked", metadata: { reason: "test" })
        end

        error = nil
        begin
          described_class.run([guard], "hello", context_wrapper, phase: :input)
        rescue Agents::Guard::Tripwire => e
          error = e
        end

        expect(error).not_to be_nil
        expect(error.message).to eq("blocked")
        expect(error.guard_name).to eq("blocker")
        expect(error.metadata).to eq({ reason: "test" })
      end

      it "emits a callback before raising" do
        guard = build_guard(name: "blocker") do |_content, _ctx|
          Agents::GuardResult.tripwire(message: "blocked")
        end

        expect do
          described_class.run([guard], "hello", context_wrapper, phase: :input)
        end.to raise_error(Agents::Guard::Tripwire)

        expect(callback_manager).to have_received(:emit_guard_triggered)
          .with("blocker", :input, :tripwire, "blocked", context_wrapper)
      end
    end

    context "with chained guards" do
      it "applies rewrites in order" do
        guard1 = build_guard { |content, _ctx| Agents::GuardResult.rewrite("#{content}!") }
        guard2 = build_guard { |content, _ctx| Agents::GuardResult.rewrite(content.upcase) }

        result = described_class.run([guard1, guard2], "hello", context_wrapper, phase: :output)
        expect(result.content).to eq("HELLO!")
      end

      it "tripwire sees rewritten content from earlier guard" do
        seen_content = nil
        guard1 = build_guard { |_content, _ctx| Agents::GuardResult.rewrite("REDACTED") }
        guard2 = build_guard(name: "checker") do |content, _ctx|
          seen_content = content
          Agents::GuardResult.tripwire(message: "still bad")
        end

        expect do
          described_class.run([guard1, guard2], "secret 123-45-6789", context_wrapper, phase: :output)
        end.to raise_error(Agents::Guard::Tripwire)

        expect(seen_content).to eq("REDACTED")
      end

      it "short-circuits on tripwire -- subsequent guards do not run" do
        guard2_called = false
        guard1 = build_guard(name: "blocker") do |_content, _ctx|
          Agents::GuardResult.tripwire(message: "blocked")
        end
        guard2 = build_guard do |_content, _ctx|
          guard2_called = true
          nil
        end

        expect do
          described_class.run([guard1, guard2], "hello", context_wrapper, phase: :input)
        end.to raise_error(Agents::Guard::Tripwire)

        expect(guard2_called).to be false
      end

      it "passes between rewrites do not reset content" do
        guard1 = build_guard { |content, _ctx| Agents::GuardResult.rewrite("#{content}!") }
        guard2 = build_guard { |_content, _ctx| nil } # pass
        guard3 = build_guard { |content, _ctx| Agents::GuardResult.rewrite(content.upcase) }

        result = described_class.run([guard1, guard2, guard3], "hello", context_wrapper, phase: :output)
        expect(result.content).to eq("HELLO!")
      end
    end

    context "with fail-open error handling (default)" do
      it "swallows unexpected errors and passes" do
        guard = build_guard { |_content, _ctx| raise "boom" }

        result = described_class.run([guard], "hello", context_wrapper, phase: :input)
        expect(result.pass?).to be true
        expect(result.content).to eq("hello")
      end

      it "still raises Guard::Tripwire even in non-strict mode" do
        guard = build_guard do |_content, _ctx|
          raise Agents::Guard::Tripwire.new("abort", guard_name: "test")
        end

        expect do
          described_class.run([guard], "hello", context_wrapper, phase: :input)
        end.to raise_error(Agents::Guard::Tripwire)
      end

      it "continues to subsequent guards after a swallowed error" do
        guard1 = build_guard { |_content, _ctx| raise "boom" }
        guard2 = build_guard { |content, _ctx| Agents::GuardResult.rewrite(content.upcase) }

        result = described_class.run([guard1, guard2], "hello", context_wrapper, phase: :input)
        expect(result.content).to eq("HELLO")
      end
    end

    context "with fail-closed error handling (strict: true)" do
      it "converts unexpected errors to tripwires" do
        guard = build_guard(name: "failing_guard") { |_content, _ctx| raise "boom" }

        error = nil
        begin
          described_class.run([guard], "hello", context_wrapper, phase: :input, strict: true)
        rescue Agents::Guard::Tripwire => e
          error = e
        end

        expect(error).not_to be_nil
        expect(error.guard_name).to eq("failing_guard")
        expect(error.message).to include("boom")
        expect(error.metadata[:original_error]).to eq("RuntimeError")
      end
    end

    context "with invalid guard return type" do
      it "raises TypeError in fail-open mode (caught by safe_execute)" do
        guard = build_guard { |_content, _ctx| "not a GuardResult" }
        # TypeError is a StandardError, so fail-open swallows it and logs
        result = described_class.run([guard], "hello", context_wrapper, phase: :input)
        expect(result.pass?).to be true
      end

      it "raises Guard::Tripwire with clear message in strict mode" do
        guard = build_guard(name: "bad_guard") { |_content, _ctx| "not a GuardResult" }

        expect do
          described_class.run([guard], "hello", context_wrapper, phase: :input, strict: true)
        end.to raise_error(Agents::Guard::Tripwire, /must return nil or GuardResult, got String/)
      end
    end

    context "with adversarial inputs" do
      it "handles nil content gracefully" do
        guard = build_guard { |content, _ctx| content.nil? ? nil : Agents::GuardResult.pass }
        result = described_class.run([guard], nil, context_wrapper, phase: :input)
        expect(result.pass?).to be true
      end

      it "handles empty string content" do
        guard = build_guard { |_content, _ctx| Agents::GuardResult.rewrite("replaced") }
        result = described_class.run([guard], "", context_wrapper, phase: :output)
        expect(result.content).to eq("replaced")
      end

      it "handles rewrite to empty string" do
        guard = build_guard { |_content, _ctx| Agents::GuardResult.rewrite("") }
        result = described_class.run([guard], "secret data", context_wrapper, phase: :output)
        expect(result.content).to eq("")
      end
    end
  end
end
