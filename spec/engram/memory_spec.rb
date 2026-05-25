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

  it "embeds content on add" do
    record = memory.add("hello")
    expect(record.embedding).to eq(embedder.embed("hello"))
  end

  it "injects recalled memories into a prompt" do
    memory.add("likes short answers")
    out = memory.inject_into("Reply to the user.", query: "likes short answers")
    expect(out).to include("- likes short answers")
  end

  it "isolates memories by scope" do
    memory.add("mine")
    other = described_class.new(scope: "user:2", store: store, embedder: embedder)
    expect(other.all).to be_empty
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
end
