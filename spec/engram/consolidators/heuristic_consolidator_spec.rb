# frozen_string_literal: true

RSpec.describe Engram::Consolidators::HeuristicConsolidator do
  subject(:consolidator) { described_class.new(store: store) }

  let(:store) { Engram::Adapters::InMemoryStore.new }
  let(:embedder) { Engram::Adapters::NullEmbedder.new }

  def candidate(text, scope: "u:1")
    Engram::Record.new(content: text, scope: scope, embedding: embedder.embed(text))
  end

  it "adds a novel candidate" do
    decisions = consolidator.reconcile_all(candidates: [candidate("plan is Pro")], scope: "u:1")
    expect(decisions.map(&:action)).to eq([:add])
  end

  it "noops a near-duplicate of an existing memory" do
    store.add(candidate("plan is Pro"))
    decisions = consolidator.reconcile_all(candidates: [candidate("plan is Pro")], scope: "u:1")
    expect(decisions.map(&:action)).to eq([:noop])
  end
end
