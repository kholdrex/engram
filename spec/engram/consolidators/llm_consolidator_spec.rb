# frozen_string_literal: true

RSpec.describe Engram::Consolidators::LLMConsolidator do
  let(:store) { Engram::Adapters::InMemoryStore.new }
  let(:embedder) { Engram::Adapters::NullEmbedder.new }

  def rec(text, scope: "u:1")
    Engram::Record.new(content: text, scope: scope, embedding: embedder.embed(text))
  end

  it "maps the LLM decision array back onto candidates" do
    existing = store.add(rec("plan is Free"))
    completion = Engram::Adapters::FakeCompletion.new(responses: [
      {"decisions" => [{"index" => 0, "action" => "update", "target_id" => existing.id, "reason" => "changed"}]}
    ])
    candidate = rec("plan is Pro")

    decisions = described_class.new(store: store, completion: completion)
      .reconcile_all(candidates: [candidate], scope: "u:1")

    expect(decisions.size).to eq(1)
    expect(decisions.first.action).to eq(:update)
    expect(decisions.first.target_id).to eq(existing.id)
    expect(decisions.first.candidate).to eq(candidate)
  end

  it "shows the nearest existing memories to the model" do
    store.add(rec("plan is Free"))
    completion = Engram::Adapters::FakeCompletion.new(responses: [{"decisions" => []}])

    described_class.new(store: store, completion: completion)
      .reconcile_all(candidates: [rec("plan is Pro")], scope: "u:1")

    expect(completion.calls.first[:user]).to include("plan is Free")
  end

  it "returns empty for no candidates without calling the LLM" do
    completion = Engram::Adapters::FakeCompletion.new
    result = described_class.new(store: store, completion: completion).reconcile_all(candidates: [], scope: "u:1")

    expect(result).to eq([])
    expect(completion.calls).to be_empty
  end
end
