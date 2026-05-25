# frozen_string_literal: true

RSpec.describe Engram::UseCases::Recall do
  subject(:recall) { described_class.new(store: store, embedder: embedder) }

  let(:store) { Engram::Adapters::InMemoryStore.new }
  let(:embedder) { Engram::Adapters::NullEmbedder.new }

  def seed(content, scope: "u:1")
    store.add(Engram::Record.new(content: content, scope: scope, embedding: embedder.embed(content)))
  end

  it "returns the exact match first for a known query" do
    seed("plan is Pro")
    seed("likes short answers")

    results = recall.call("plan is Pro", scope: "u:1", limit: 1)
    expect(results.first.content).to eq("plan is Pro")
  end

  it "raises on an empty query" do
    expect { recall.call("  ", scope: "u:1") }.to raise_error(ArgumentError)
  end

  it "recalls only within scope" do
    seed("secret", scope: "u:2")
    expect(recall.call("secret", scope: "u:1", limit: 5)).to be_empty
  end
end
