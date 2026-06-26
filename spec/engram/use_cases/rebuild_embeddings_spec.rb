# frozen_string_literal: true

RSpec.describe Engram::UseCases::RebuildEmbeddings do
  subject(:rebuild) { described_class.new(store: store, embedder: embedder) }

  let(:store) { Engram::Adapters::InMemoryStore.new }
  let(:embedder) { Engram::Adapters::NullEmbedder.new }

  def add_record(content:, scope: "u:1", metadata: nil)
    record = Engram::Record.new(
      content: content,
      scope: scope,
      embedding: embedder.embed(content),
      metadata: metadata || {}
    )
    record = Engram::EmbeddingMetadata.attach(record, embedder: embedder) if metadata.nil?
    store.add(record)
  end

  it "updates stale records by default" do
    stale = Engram::Record.new(content: "hello", scope: "u:1", embedding: embedder.embed("hello"))
    fresh = Engram::Record.new(content: "world", scope: "u:1", embedding: embedder.embed("world"), metadata: {})
    fresh = Engram::EmbeddingMetadata.attach(fresh, embedder: embedder)
    store.add(stale)
    store.add(fresh)

    result = rebuild.call(scope: "u:1")

    expect(result[:processed]).to eq(2)
    expect(result[:updated]).to eq(1)
    expect(result[:skipped]).to eq(1)
    expect(result[:failed]).to eq(0)

    rebuilt = store.all(scope: "u:1").find { |record| record.content == "hello" }
    expect(rebuilt.metadata).to include("_engram" => include("embedding" => include("fingerprint" => be_a(String))))
  end

  it "honors stale_only: false and rebuilds all records" do
    add_record(content: "first")
    add_record(content: "second")

    result = rebuild.call(scope: "u:1", stale_only: false, batch_size: 1)

    expect(result[:updated]).to eq(2)
    expect(result[:skipped]).to eq(0)
    expect(result[:processed]).to eq(2)
  end

  it "walks multiple batches without skipping records" do
    add_record(content: "first")
    add_record(content: "second")
    add_record(content: "third")

    result = rebuild.call(scope: "u:1", stale_only: false, batch_size: 2)

    expect(result[:processed]).to eq(3)
    expect(result[:updated]).to eq(3)
    expect(result[:skipped]).to eq(0)
  end

  it "only processes records in the requested scope" do
    add_record(content: "in_scope", metadata: {})
    add_record(content: "other_scope", scope: "u:2", metadata: {})

    result = rebuild.call(scope: "u:1")

    expect(result[:processed]).to eq(1)
    expect(result[:updated]).to eq(1)
  end

  it "rebuilds records with mismatched embedding metadata" do
    incompatible = Engram::Record.new(
      content: "gamma",
      scope: "u:1",
      embedding: embedder.embed("gamma"),
      metadata: {
        "_engram" => {
          "embedding" => {
            "adapter" => "Engram::Adapters::NullEmbedder",
            "provider" => "null",
            "model" => "legacy",
            "dimensions" => embedder.dimensions,
            "fingerprint" => "different"
          }
        }
      }
    )
    store.add(incompatible)

    result = rebuild.call(scope: "u:1")

    expect(result[:updated]).to eq(1)
    expect(store.all(scope: "u:1").first.metadata.dig("_engram", "embedding", "fingerprint")).to eq(
      Engram::EmbeddingMetadata.for_embedder(embedder, embedding: embedder.embed("gamma"))["fingerprint"]
    )
  end

  it "raises on non-positive batch size" do
    expect do
      rebuild.call(scope: "u:1", batch_size: 0)
    end.to raise_error(ArgumentError, "batch_size must be greater than 0")
  end

  it "tracks failed rows when embedding fails" do
    stale_record = Engram::Record.new(
      content: "broken",
      scope: "u:1",
      embedding: embedder.embed("broken"),
      metadata: {}
    )
    store.add(stale_record)

    allow(embedder).to receive(:embed).and_raise(StandardError, "transform failed")

    result = rebuild.call(scope: "u:1")

    expect(result[:processed]).to eq(1)
    expect(result[:updated]).to eq(0)
    expect(result[:failed]).to eq(1)
    expect(result[:failed_ids]).to eq([1])
    expect(result[:failed_errors]).to include(
      1 => {
        class: "StandardError",
        message: "transform failed"
      }
    )
    expect(result[:skipped]).to eq(0)
  end
end
