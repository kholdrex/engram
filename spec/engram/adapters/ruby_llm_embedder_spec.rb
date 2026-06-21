# frozen_string_literal: true

RSpec.describe Engram::Adapters::RubyLLMEmbedder do
  subject(:embedder) { described_class.new(model: "custom-embedding", dimensions: 42) }

  it "exposes the configured model" do
    expect(embedder.model).to eq("custom-embedding")
  end

  it "exposes embedding metadata for mismatch detection" do
    expect(embedder.embedding_metadata).to include(
      "adapter" => "Engram::Adapters::RubyLLMEmbedder",
      "provider" => "ruby_llm",
      "model" => "custom-embedding",
      "dimensions" => 42
    )
    expect(embedder.embedding_metadata["fingerprint"]).not_to be_empty
  end
end
