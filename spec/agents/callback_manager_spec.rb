# frozen_string_literal: true

require_relative "../../lib/agents"

RSpec.describe Agents::CallbackManager do
  describe "#initialize" do
    it "stores empty callbacks when none provided" do
      manager = described_class.new
      expect(manager.instance_variable_get(:@callbacks)).to eq({})
    end

    it "stores provided callbacks" do
      callbacks = { tool_start: [proc { "test" }] }
      manager = described_class.new(callbacks)
      expect(manager.instance_variable_get(:@callbacks)).to eq(callbacks)
    end

    it "duplicates and freezes callbacks for thread safety" do
      callbacks = { tool_start: [] }
      manager = described_class.new(callbacks)
      stored_callbacks = manager.instance_variable_get(:@callbacks)

      expect(stored_callbacks).to be_frozen
      expect(stored_callbacks).not_to be(callbacks)
    end
  end

  describe "#emit" do
    it "calls all callbacks for the event type" do
      callback1 = instance_double(Proc, lambda?: false)
      callback2 = instance_double(Proc, lambda?: false)
      callbacks = { tool_start: [callback1, callback2] }
      manager = described_class.new(callbacks)

      allow(callback1).to receive(:call)
      allow(callback2).to receive(:call)

      manager.emit(:tool_start, "tool_name", { arg: "value" })

      expect(callback1).to have_received(:call).with("tool_name", { arg: "value" })
      expect(callback2).to have_received(:call).with("tool_name", { arg: "value" })
    end

    it "does nothing when no callbacks registered for event" do
      manager = described_class.new
      expect { manager.emit(:tool_start, "tool_name") }.not_to raise_error
    end

    it "handles callback errors gracefully" do
      failing_callback = proc { raise StandardError, "Callback error" }
      callbacks = { tool_start: [failing_callback] }
      manager = described_class.new(callbacks)

      expect { manager.emit(:tool_start, "tool_name") }.to output(/Callback error for tool_start/).to_stderr
    end

    it "continues executing remaining callbacks after one fails" do
      failing_callback = proc { raise StandardError, "Callback error" }
      success_callback = instance_double(Proc, lambda?: false)
      callbacks = { tool_start: [failing_callback, success_callback] }
      manager = described_class.new(callbacks)

      allow(success_callback).to receive(:call)

      expect { manager.emit(:tool_start, "tool_name") }.to output(/Callback error/).to_stderr
      expect(success_callback).to have_received(:call).with("tool_name")
    end
  end

  describe "typed emit methods" do
    let(:callback) { instance_double(Proc, lambda?: false) }
    let(:manager) do
      described_class.new(
        run_start: [callback],
        run_complete: [callback],
        agent_complete: [callback],
        tool_start: [callback],
        tool_complete: [callback],
        agent_thinking: [callback],
        agent_handoff: [callback],
        llm_call_complete: [callback],
        chat_created: [callback]
      )
    end

    before do
      allow(callback).to receive(:call)
    end

    it "has emit_run_start method" do
      manager.emit_run_start("agent_name", "input", "context")
      expect(callback).to have_received(:call).with("agent_name", "input", "context")
    end

    it "has emit_run_complete method" do
      manager.emit_run_complete("agent_name", "result", "context")
      expect(callback).to have_received(:call).with("agent_name", "result", "context")
    end

    it "has emit_agent_complete method" do
      manager.emit_agent_complete("agent_name", "result", "error", "context")
      expect(callback).to have_received(:call).with("agent_name", "result", "error", "context")
    end

    it "has emit_tool_start method" do
      manager.emit_tool_start("tool_name", { key: "value" })
      expect(callback).to have_received(:call).with("tool_name", { key: "value" })
    end

    it "has emit_tool_complete method" do
      manager.emit_tool_complete("tool_name", "result")
      expect(callback).to have_received(:call).with("tool_name", "result")
    end

    it "has emit_agent_thinking method" do
      manager.emit_agent_thinking("agent_name", "input")
      expect(callback).to have_received(:call).with("agent_name", "input")
    end

    it "has emit_agent_handoff method" do
      manager.emit_agent_handoff("from_agent", "to_agent", "reason")
      expect(callback).to have_received(:call).with("from_agent", "to_agent", "reason")
    end

    it "has emit_llm_call_complete method" do
      manager.emit_llm_call_complete("agent_name", "gpt-4o", "response", "context")
      expect(callback).to have_received(:call).with("agent_name", "gpt-4o", "response", "context")
    end

    it "has emit_chat_created method" do
      manager.emit_chat_created("chat", "agent_name", "gpt-4o", "context")
      expect(callback).to have_received(:call).with("chat", "agent_name", "gpt-4o", "context")
    end
  end

  describe "arity-safe dispatch" do
    it "slices args for lambdas with strict arity" do
      received_args = nil
      # Lambda with strict arity of 2 — should NOT receive the 3rd arg (context_wrapper)
      strict_lambda = ->(tool_name, args) { received_args = [tool_name, args] }
      manager = described_class.new(tool_start: [strict_lambda])

      manager.emit(:tool_start, "my_tool", { key: "val" }, "extra_context_wrapper")

      expect(received_args).to eq(["my_tool", { key: "val" }])
    end

    it "passes all args to procs with flexible arity" do
      received_args = nil
      flexible_proc = proc { |*args| received_args = args }
      manager = described_class.new(tool_start: [flexible_proc])

      manager.emit(:tool_start, "my_tool", { key: "val" }, "extra_context_wrapper")

      expect(received_args).to eq(["my_tool", { key: "val" }, "extra_context_wrapper"])
    end

    it "handles mixed lambda and proc callbacks" do
      lambda_args = nil
      proc_args = nil
      strict_lambda = ->(name, args) { lambda_args = [name, args] }
      flexible_proc = proc { |*args| proc_args = args }
      manager = described_class.new(tool_start: [strict_lambda, flexible_proc])

      manager.emit(:tool_start, "my_tool", { key: "val" }, "context")

      expect(lambda_args).to eq(["my_tool", { key: "val" }])
      expect(proc_args).to eq(["my_tool", { key: "val" }, "context"])
    end

    it "slices args for lambdas with optional parameters" do
      received_args = nil
      # Lambda with 2 required + 1 optional: accepts 2..3 args, NOT 4
      optional_lambda = ->(tool_name, args, extra = nil) { received_args = [tool_name, args, extra] }
      manager = described_class.new(tool_start: [optional_lambda])

      manager.emit(:tool_start, "my_tool", { key: "val" }, "context", "extra_ignored")

      expect(received_args).to eq(["my_tool", { key: "val" }, "context"])
    end

    it "passes all args to lambdas with rest parameter" do
      received_args = nil
      splat_lambda = ->(tool_name, *rest) { received_args = [tool_name, rest] }
      manager = described_class.new(tool_start: [splat_lambda])

      manager.emit(:tool_start, "my_tool", { key: "val" }, "context", "extra")

      expect(received_args).to eq(["my_tool", [{ key: "val" }, "context", "extra"]])
    end
  end

  describe "thread safety" do
    it "can be safely used from multiple threads" do
      shared_data = []
      callback = proc { |data| shared_data << data }
      manager = described_class.new(tool_start: [callback])

      threads = 5.times.map do |i|
        Thread.new do
          manager.emit_tool_start("tool_#{i}")
        end
      end

      threads.each(&:join)

      expect(shared_data.length).to eq(5)
      expect(shared_data).to include("tool_0", "tool_1", "tool_2", "tool_3", "tool_4")
    end
  end
end
