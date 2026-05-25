# frozen_string_literal: true

RSpec.describe Engram::UseCases::Observe do
  let(:store) { Engram::Adapters::InMemoryStore.new }
  let(:embedder) { Engram::Adapters::NullEmbedder.new }

  def extraction(*facts)
    {"facts" => facts.map { |f| {"content" => f, "confidence" => 0.9} }}
  end

  def extractor_for(completion)
    Engram::Extractors::LLMExtractor.new(completion: completion, embedder: embedder)
  end

  it "extracts and adds new memories (heuristic consolidator)" do
    completion = Engram::Adapters::FakeCompletion.new(responses: [extraction("User likes tea")])
    consolidator = Engram::Consolidators::HeuristicConsolidator.new(store: store)

    decisions = described_class.new(store: store, extractor: extractor_for(completion), consolidator: consolidator)
      .call(messages: ["I really like tea"], scope: "u:1")

    expect(decisions.map(&:action)).to eq([:add])
    expect(store.all(scope: "u:1").map(&:content)).to eq(["User likes tea"])
  end

  it "applies an UPDATE decision (llm consolidator)" do
    existing = store.add(Engram::Record.new(content: "User is on Free", scope: "u:1",
      embedding: embedder.embed("User is on Free")))
    completion = Engram::Adapters::FakeCompletion.new(responses: [
      extraction("User is on Pro"),
      {"decisions" => [{"index" => 0, "action" => "update", "target_id" => existing.id}]}
    ])
    consolidator = Engram::Consolidators::LLMConsolidator.new(store: store, completion: completion)

    described_class.new(store: store, extractor: extractor_for(completion), consolidator: consolidator)
      .call(messages: ["upgraded to pro"], scope: "u:1")

    expect(store.all(scope: "u:1").map(&:content)).to eq(["User is on Pro"])
  end

  it "does nothing when nothing is extracted" do
    completion = Engram::Adapters::FakeCompletion.new(responses: [{"facts" => []}])
    consolidator = Engram::Consolidators::HeuristicConsolidator.new(store: store)

    decisions = described_class.new(store: store, extractor: extractor_for(completion), consolidator: consolidator)
      .call(messages: ["hi"], scope: "u:1")

    expect(decisions).to eq([])
    expect(store.all(scope: "u:1")).to be_empty
  end

  it "applies the persistence policy before storing observed memories" do
    completion = Engram::Adapters::FakeCompletion.new(responses: [extraction("User API key is sk-test-secret")])
    consolidator = Engram::Consolidators::HeuristicConsolidator.new(store: store)

    decisions = described_class.new(store: store, extractor: extractor_for(completion), consolidator: consolidator)
      .call(messages: ["my API key is sk-test-secret"], scope: "u:1")

    expect(decisions.map(&:action)).to eq([:add])
    expect(store.all(scope: "u:1")).to be_empty
  end

  it "skips a turn already processed under the same idempotency key" do
    completion = Engram::Adapters::FakeCompletion.new(responses: [extraction("User likes tea")])
    consolidator = Engram::Consolidators::HeuristicConsolidator.new(store: store)
    processed = Engram::Adapters::InMemoryProcessedTurns.new
    observe = described_class.new(
      store: store, extractor: extractor_for(completion), consolidator: consolidator,
      processed_turns: processed
    )

    first = observe.call(messages: ["I like tea"], scope: "u:1", idempotency_key: "turn-1")
    second = observe.call(messages: ["I like tea"], scope: "u:1", idempotency_key: "turn-1")

    expect(first.map(&:action)).to eq([:add])
    expect(second).to eq([])
    expect(store.all(scope: "u:1").size).to eq(1)
    expect(completion.calls.size).to eq(1) # extraction did not run again
  end
end
