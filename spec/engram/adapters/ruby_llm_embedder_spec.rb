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

  it "defaults dimensions to the default model's vector size" do
    expect(described_class.new.dimensions).to eq(described_class::DEFAULT_DIMENSIONS)
  end

  it "rejects invalid dimensions" do
    [0, -1, "42", 42.5].each do |dimensions|
      expect { described_class.new(dimensions: dimensions) }
        .to raise_error(ArgumentError, "dimensions must be a positive integer")
    end
  end

  describe "#embed" do
    def stub_ruby_llm(vectors:, dimensions_kwarg: true, &recorder)
      result = Struct.new(:vectors).new(vectors)
      fake = Module.new
      if dimensions_kwarg
        fake.define_singleton_method(:embed) do |text, model:, dimensions: nil|
          recorder&.call(model: model, dimensions: dimensions)
          result
        end
      else
        fake.define_singleton_method(:embed) do |text, model:|
          recorder&.call(model: model)
          result
        end
      end
      stub_const("RubyLLM", fake)
    end

    it "requests explicitly configured dimensions from the provider" do
      requests = []
      stub_ruby_llm(vectors: [0.1] * 42) { |request| requests << request }

      expect(embedder.embed("hello")).to eq([0.1] * 42)
      expect(requests).to eq([{model: "custom-embedding", dimensions: 42}])
    end

    it "does not request dimensions when they were not explicitly configured" do
      requests = []
      stub_ruby_llm(vectors: [0.1] * described_class::DEFAULT_DIMENSIONS) { |request| requests << request }

      described_class.new.embed("hello")
      expect(requests).to eq([{model: described_class::DEFAULT_MODEL, dimensions: nil}])
    end

    it "falls back to a plain request on RubyLLM versions without the dimensions kwarg" do
      requests = []
      stub_ruby_llm(vectors: [0.1] * 42, dimensions_kwarg: false) { |request| requests << request }

      expect(embedder.embed("hello")).to eq([0.1] * 42)
      expect(requests).to eq([{model: "custom-embedding"}])
    end

    it "raises a clear error when the model output does not match the configured dimensions" do
      stub_ruby_llm(vectors: [0.1] * 1536)

      expect { embedder.embed("hello") }.to raise_error(
        Engram::Error, /returned 1536-dimension output.*dimensions: 42/m
      )
    end
  end
end
