# frozen_string_literal: true

RSpec.describe Engram::UseCases::Recall do
  subject(:recall) { described_class.new(store: store, embedder: embedder) }

  let(:store) { Engram::Adapters::InMemoryStore.new }
  let(:embedder) { Engram::Adapters::NullEmbedder.new }

  def seed(content, scope: "u:1", kind: :fact)
    store.add(Engram::Record.new(content: content, scope: scope, embedding: embedder.embed(content), kind: kind))
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

  it "does not leak adversarially similar memories from another scope" do
    seed("billing contact is alex@example.test", scope: "u:1")
    seed("billing contact is blair@example.test", scope: "u:2")

    results = recall.call("billing contact", scope: "u:1", limit: 5)

    expect(results.map(&:content)).to eq(["billing contact is alex@example.test"])
  end

  it "keeps nil and blank scopes from acting as wildcards" do
    seed("blank scope memory", scope: "")
    seed("named scope memory", scope: "u:1")

    expect(recall.call("scope memory", scope: nil, limit: 5)).to be_empty
    expect(recall.call("scope memory", scope: "", limit: 5).map(&:content)).to eq(["blank scope memory"])
  end

  it "recalls only requested memory kinds" do
    seed("prefers concise answers", kind: :preference)
    seed("billing tier is Pro", kind: :fact)

    results = recall.call("answers", scope: "u:1", limit: 5, kinds: [:preference])

    expect(results.map(&:content)).to eq(["prefers concise answers"])
  end

  describe "ranking" do
    let(:fixed_embedder) do
      Class.new do
        def embed(_text)
          [1.0, 0.0]
        end

        def dimensions
          2
        end
      end.new
    end

    def store_record(content, embedding:, importance: 1.0, created_at: Time.now, kind: :fact)
      store.add(Engram::Record.new(content: content, scope: "u:1", embedding: embedding,
        importance: importance, created_at: created_at, kind: kind))
    end

    it "filters before applying the recall limit" do
      store_record("near fact", embedding: [1.0, 0.0], kind: :fact)
      store_record("near preference", embedding: [0.9, 0.1], kind: :preference)

      results = described_class.new(store: store, embedder: fixed_embedder)
        .call("q", scope: "u:1", limit: 1, kinds: [:preference])

      expect(results.map(&:content)).to eq(["near preference"])
    end

    it "orders by pure similarity when weights are zero" do
      store_record("near", embedding: [1.0, 0.0])
      store_record("far", embedding: [0.2, 1.0])

      results = described_class.new(store: store, embedder: fixed_embedder)
        .call("q", scope: "u:1", limit: 2)
      expect(results.map(&:content)).to eq(["near", "far"])
    end

    it "promotes important memories when importance_weight is set" do
      store_record("near but trivial", embedding: [1.0, 0.0], importance: 0.0)
      store_record("less similar but important", embedding: [0.9, 0.1], importance: 1.0)

      top = described_class.new(store: store, embedder: fixed_embedder, importance_weight: 1.0)
        .call("q", scope: "u:1", limit: 1).first
      expect(top.content).to eq("less similar but important")
    end

    it "promotes recent memories when recency_weight is set" do
      store_record("old", embedding: [1.0, 0.0], created_at: Time.now - (90 * 24 * 60 * 60))
      store_record("new", embedding: [1.0, 0.0], created_at: Time.now)

      top = described_class.new(store: store, embedder: fixed_embedder, recency_weight: 1.0)
        .call("q", scope: "u:1", limit: 1).first
      expect(top.content).to eq("new")
    end

    it "touches recalled memories when touch is enabled" do
      store_record("x", embedding: [1.0, 0.0])
      described_class.new(store: store, embedder: fixed_embedder, touch: true)
        .call("q", scope: "u:1", limit: 1)
      expect(store.all(scope: "u:1").first.last_accessed_at).not_to be_nil
    end
  end
end
