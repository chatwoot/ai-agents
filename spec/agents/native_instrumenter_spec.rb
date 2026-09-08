# frozen_string_literal: true

RSpec.describe Agents::NativeInstrumenter do
  let(:events) { [] }
  let(:run_context) do
    Agents::RunContext.new({}, callbacks: { native_event: [->(*args) { events << args }] })
  end
  let(:upstream) { instance_double(described_class) }
  let(:instrumenter) { described_class.new(run_context, upstream) }

  it "forwards operations to the existing instrumenter and preserves their return value" do
    payload = {}
    allow(upstream).to receive(:instrument).with("chat.ruby_llm", payload).and_yield

    result = instrumenter.instrument("chat.ruby_llm", payload) { "Answer" }

    expect(result).to eq("Answer")
    expect(events.map(&:first)).to eq(%i[start finish])
    expect(events.last.last).to be(run_context)
  end

  it "records failed attempt usage without pretending unknown cost is zero" do
    payload = { status: :failed, tokens: RubyLLM::Tokens.new(input: 10), cost: RubyLLM::Cost.new }
    allow(upstream).to receive(:instrument)

    instrumenter.instrument("usage.ruby_llm", payload)

    expect(run_context.usage.tokens.input).to eq(10)
    expect(run_context.usage.cost.total).to be_nil
    expect(upstream).to have_received(:instrument).with("usage.ruby_llm", payload)
  end

  it "emits completion with the original error before re-raising" do
    instrumenter = described_class.new(run_context)
    error = StandardError.new("Provider failed")

    expect { instrumenter.instrument("chat.ruby_llm", {}) { raise error } }.to raise_error(error)

    expect(events.last[0]).to eq(:finish)
    expect(events.last[2][:error]).to be(error)
  end
end
