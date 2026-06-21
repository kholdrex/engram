# frozen_string_literal: true

RSpec.describe Engram::Memory do
  subject(:memory) { described_class.new(scope: "user:1", store: store, embedder: embedder) }

  let(:store) { Engram::Adapters::InMemoryStore.new }
  let(:embedder) { Engram::Adapters::NullEmbedder.new }

  it "adds and recalls a fact" do
    memory.add("tariff plan is Pro")
    results = memory.recall("tariff plan is Pro", limit: 1)
    expect(results.first.content).to eq("tariff plan is Pro")
  end

  it "recalls only requested memory kinds" do
    memory.add("likes short answers", kind: :preference)
    memory.add("tariff plan is Pro", kind: :fact)

    results = memory.recall("answers", limit: 5, kinds: [:preference])

    expect(results.map(&:content)).to eq(["likes short answers"])
  end

  it "embeds content on add" do
    record = memory.add("hello")
    expect(record.embedding).to eq(embedder.embed("hello"))
  end

  it "stores embedding metadata under the reserved namespace on add" do
    record = memory.add("hello", metadata: {source: "spec"})

    expect(record.metadata).to include(source: "spec")
    expect(record.metadata.dig("_engram", "embedding")).to include(
      "adapter" => "Engram::Adapters::NullEmbedder",
      "model" => "null-embedder-v1",
      "dimensions" => 16
    )
  end

  it "raises clearly when user metadata collides with Engram's reserved namespace" do
    expect do
      memory.add("hello", metadata: {"_engram" => "user data"})
    end.to raise_error(Engram::Error, /reserved for Engram embedding metadata/)

    expect do
      memory.add("hello", metadata: {"_engram" => {"user" => "data"}})
    end.to raise_error(Engram::Error, /reserved for Engram embedding metadata/)

    expect do
      memory.add("hello", metadata: {"_engram" => {}, :_engram => {user: "data"}})
    end.to raise_error(Engram::Error, /reserved for Engram embedding metadata/)
  end

  it "applies the default persistence policy on add" do
    result = memory.add("User API key is fake-token-abcdef")

    expect(result).to be_nil
    expect(memory.all).to be_empty
  end

  it "applies the configured before_persist hook on add" do
    Engram.config.before_persist = lambda do |record|
      record.with(content: record.content.gsub("billing@example.test", "[REDACTED]"))
    end

    record = memory.add("User billing email is billing@example.test")

    expect(record.content).to eq("User billing email is [REDACTED]")
    expect(record.embedding).to eq(embedder.embed("User billing email is [REDACTED]"))
    expect(record.metadata.dig("_engram", "embedding", "dimensions")).to eq(16)
    expect(memory.all.map(&:content)).to eq(["User billing email is [REDACTED]"])
  end

  it "injects recalled memories into a prompt" do
    memory.add("likes short answers")
    out = memory.inject_into("Reply to the user.", query: "likes short answers")
    expect(out).to include('<engram-memory kind="fact">likes short answers</engram-memory>')
  end

  it "injects only requested memory kinds" do
    memory.add("likes short answers", kind: :preference)
    memory.add("tariff plan is Pro", kind: :fact)

    out = memory.inject_into("Reply to the user.", query: "answers", limit: 5, kinds: [:preference])

    expect(out).to include("likes short answers")
    expect(out).not_to include("tariff plan is Pro")
  end

  it "isolates memories by scope" do
    memory.add("mine")
    other = described_class.new(scope: "user:2", store: store, embedder: embedder)
    expect(other.all).to be_empty
  end

  it "keeps similar recalled and injected memories isolated to the facade scope" do
    memory.add("billing contact is alex@example.test")
    described_class.new(scope: "user:2", store: store, embedder: embedder)
      .add("billing contact is blair@example.test")

    results = memory.recall("billing contact", limit: 5)
    out = memory.inject_into("Reply to the user.", query: "billing contact", limit: 5)

    expect(results.map(&:content)).to eq(["billing contact is alex@example.test"])
    expect(out).to include("billing contact is alex@example.test")
    expect(out).not_to include("billing contact is blair@example.test")
  end

  it "rejects nil scope persistence and treats blank scope as isolated" do
    nil_scoped = described_class.new(scope: nil, store: store, embedder: embedder)
    blank_scoped = described_class.new(scope: "", store: store, embedder: embedder)

    blank_scoped.add("blank scope memory")

    expect { nil_scoped.add("nil scope memory") }.to raise_error(Engram::Error, "memory scope cannot be nil")
    expect(nil_scoped.all).to be_empty
    expect(blank_scoped.all.map(&:content)).to eq(["blank scope memory"])
    expect(memory.all).to be_empty
  end

  it "observes a turn and stores derived memories" do
    completion = Engram::Adapters::FakeCompletion.new(responses: [
      {"facts" => [{"content" => "User likes tea", "confidence" => 0.9}]}
    ])
    memory.observe(["I like tea"], completion: completion)
    expect(memory.all.map(&:content)).to eq(["User likes tea"])
  end

  it "raises on observe without a completion" do
    expect { memory.observe(["hi"], completion: nil) }.to raise_error(Engram::Error)
  end

  it "is idempotent for a repeated turn" do
    completion = Engram::Adapters::FakeCompletion.new(responses: [
      {"facts" => [{"content" => "User likes tea", "confidence" => 0.9}]}
    ])
    memory.observe(["I like tea"], completion: completion)
    memory.observe(["I like tea"], completion: completion)

    expect(memory.all.map(&:content)).to eq(["User likes tea"])
    expect(completion.calls.size).to eq(1)
  end

  it "forgets stale memories via the facade" do
    store.add(Engram::Record.new(content: "old", scope: "user:1",
      embedding: embedder.embed("old"), created_at: Time.now - (40 * 24 * 60 * 60)))
    memory.forget_stale(older_than: 30 * 24 * 60 * 60)
    expect(memory.all).to be_empty
  end
end
