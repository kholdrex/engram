# frozen_string_literal: true

RSpec.describe Engram::Adapters::NullEmbedder do
  subject(:embedder) { described_class.new(dimensions: 16) }

  it "produces vectors of the configured dimensionality" do
    expect(embedder.embed("hello").size).to eq(16)
  end

  it "is deterministic for equal text" do
    expect(embedder.embed("hello")).to eq(embedder.embed("hello"))
  end

  it "differs for different text" do
    expect(embedder.embed("hello")).not_to eq(embedder.embed("world"))
  end

  it "stays within [-1.0, 1.0]" do
    expect(embedder.embed("hello")).to all(be_between(-1.0, 1.0))
  end

  it "exposes stable embedding metadata" do
    expect(embedder.embedding_metadata).to include(
      "adapter" => "Engram::Adapters::NullEmbedder",
      "provider" => "null",
      "model" => "null-embedder-v1",
      "dimensions" => 16
    )
    expect(embedder.embedding_metadata["fingerprint"]).not_to be_empty
    expect(embedder.embedding_metadata["fingerprint"]).to eq(described_class.new(dimensions: 16).embedding_metadata["fingerprint"])
  end
end
