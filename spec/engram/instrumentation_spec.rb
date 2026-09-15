# frozen_string_literal: true

RSpec.describe "Engram instrumentation" do
  let(:events) { [] }
  let(:store) { Engram::Adapters::InMemoryStore.new }
  let(:embedder) { Engram::Adapters::NullEmbedder.new }

  before do
    Engram.config.instrumentation_scope_identifier = ->(scope) { scope.to_s }

    stub_const("ActiveSupport", Module.new)
    notifications = Class.new do
      class << self
        attr_accessor :events

        def instrument(name, payload)
          events << [name, payload]
          yield
        end
      end
    end
    notifications.events = events
    ActiveSupport.const_set(:Notifications, notifications)
  end

  it "is a no-op when ActiveSupport notifications are unavailable" do
    hide_const("ActiveSupport")

    result = Engram::Instrumentation.instrument("recall", test: true) { "ok" }

    expect(result).to eq("ok")
  end

  it "emits recall metrics without query or memory content" do
    store.add(Engram::Record.new(content: "User likes tea", scope: "u:1", embedding: embedder.embed("User likes tea")))

    result = Engram::UseCases::Recall.new(store: store, embedder: embedder)
      .call("likes tea", scope: "u:1", limit: 1)

    expect(result.map(&:content)).to eq(["User likes tea"])
    name, payload = events.fetch(0)
    expect(name).to eq("recall.engram")
    expect(payload).to include(
      scope_identifier: "u:1",
      store_adapter: "Engram::Adapters::InMemoryStore",
      limit: 1,
      kinds: [],
      reranking: false,
      candidate_count: 1,
      result_count: 1,
      duration_ms: be_a(Float).or(be_a(Integer))
    )
    expect(payload.values.join(" ")).not_to include("likes tea")
  end

  it "omits scope identifiers unless the application opts in" do
    Engram.config.instrumentation_scope_identifier = nil
    store.add(Engram::Record.new(content: "User likes tea", scope: "u:1", embedding: embedder.embed("User likes tea")))

    Engram::UseCases::Recall.new(store: store, embedder: embedder)
      .call("likes tea", scope: "u:1", limit: 1)

    expect(events.fetch(0).last).not_to have_key(:scope_identifier)
  end

  it "emits observe, extract, and consolidate metrics without message or candidate content" do
    completion = Engram::Adapters::FakeCompletion.new(
      responses: [{"facts" => [{"content" => "User likes tea", "confidence" => 0.9}]}]
    )
    extractor = Engram::Extractors::LLMExtractor.new(completion: completion, embedder: embedder)
    consolidator = Engram::Consolidators::HeuristicConsolidator.new(store: store)

    decisions = Engram::UseCases::Observe.new(store: store, extractor: extractor, consolidator: consolidator)
      .call(messages: ["I like tea"], scope: "u:1", idempotency_key: "turn-1")

    expect(decisions.map(&:action)).to eq([:add])
    expect(events.map(&:first)).to eq(["observe.engram", "extract.engram", "consolidate.engram"])
    event_payloads = events.to_h
    expect(event_payloads.fetch("observe.engram")).to include(
      scope_identifier: "u:1", store_adapter: "Engram::Adapters::InMemoryStore",
      message_count: 1, idempotency_key_present: true, candidate_count: 1,
      decision_count: 1, decision_actions: ["add"], duration_ms: be_a(Float).or(be_a(Integer))
    )
    expect(event_payloads.fetch("extract.engram")).to include(
      scope_identifier: "u:1", store_adapter: "Engram::Adapters::InMemoryStore",
      message_count: 1, candidate_count: 1, duration_ms: be_a(Float).or(be_a(Integer))
    )
    expect(event_payloads.fetch("consolidate.engram")).to include(
      scope_identifier: "u:1", store_adapter: "Engram::Adapters::InMemoryStore",
      candidate_count: 1, decision_count: 1, decision_actions: ["add"],
      duration_ms: be_a(Float).or(be_a(Integer))
    )
    expect(events.flat_map { |_name, payload| payload.values }.join(" ")).not_to include("tea")
  end

  it "emits inject metrics without injected memory content" do
    prompt = Engram::UseCases::Inject.new.call(
      prompt: "Answer safely",
      memories: [Engram::Record.new(content: "User likes tea", scope: "u:1")]
    )

    expect(prompt).to include("User likes tea")
    expect(events.fetch(0).first).to eq("inject.engram")
    expect(events.fetch(0).last).to include(memory_count: 1, duration_ms: be_a(Float).or(be_a(Integer)))
  end

  it "emits add metrics without persisted content" do
    memory = Engram::Memory.new(scope: "u:1", store: store, embedder: embedder)

    memory.add("User likes tea", kind: :preference)

    expect(events.fetch(0).first).to eq("add.engram")
    expect(events.fetch(0).last).to include(
      scope_identifier: "u:1",
      store_adapter: "Engram::Adapters::InMemoryStore",
      kind: :preference,
      duration_ms: be_a(Float).or(be_a(Integer))
    )
  end

  it "emits expiry cleanup counts without memory content or IDs" do
    Engram.config.instrumentation_scope_identifier = nil
    store.add(Engram::Record.new(content: "private trial", scope: "u:1", expires_at: Time.utc(1970, 1, 1)))
    Engram::Memory.new(scope: "u:1", store: store).forget_expired

    name, payload = events.fetch(0)
    expect(name).to eq("forget_expired.engram")
    expect(payload).to include(matched: 1, deleted: 1, dry_run: false)
    expect(payload.keys).to contain_exactly(:matched, :deleted, :dry_run, :store_adapter, :duration_ms)
  end

  it "reports deletion counts without record ids, content, or raw scope" do
    Engram.config.instrumentation_scope_identifier = nil
    record = store.add(Engram::Record.new(content: "private memory", scope: "private scope"))
    memory = Engram::Memory.new(scope: "private scope", store: store, embedder: embedder)

    memory.forget(id: record.id)
    memory.forget(id: record.id)

    expect(events.map(&:first)).to eq(["forget.engram", "forget.engram"])
    expect(events.map { |_, payload| payload[:deleted_count] }).to eq([1, 0])
    events.each do |_, payload|
      expect(payload.keys).to contain_exactly(:store_adapter, :deleted_count, :duration_ms)
      expect(payload[:store_adapter]).to eq("Engram::Adapters::InMemoryStore")
    end
  end

  it "reports threshold exclusions without content or vector data" do
    allow(embedder).to receive(:embed).and_return([1.0, 0.0])
    store.add(Engram::Record.new(content: "private memory", scope: "u:1", embedding: [0.0, 1.0]))
    Engram::UseCases::Recall.new(store: store, embedder: embedder)
      .call("private query", scope: "u:1", min_similarity: 0.5)

    payload = events.fetch(0).last
    expect(payload).to include(candidate_count: 1, filtered_count: 1, result_count: 0, min_similarity: 0.5)
    expect(payload.values.join(" ")).not_to include("private")
    expect(payload).not_to have_key(:embedding)
  end

  it "reports the actual appended bytes and skipped memory count" do
    output = Engram::UseCases::Inject.new.call(prompt: "P", max_bytes: 200,
      memories: [Engram::Record.new(content: "large" * 200, scope: "u:1"),
        Engram::Record.new(content: "small", scope: "u:1")])

    payload = events.fetch(0).last
    expect(payload).to include(memory_count: 2, injected_count: 1, skipped_count: 1,
      injected_bytes: output.bytesize - 1, max_bytes: 200)
    expect(payload.values.join(" ")).not_to include("large", "small")
  end

  it "emits zero counts when recall is disabled" do
    Engram::UseCases::Recall.new(store: store, embedder: embedder).call("q", scope: "u:1", limit: 0)

    expect(events.fetch(0).last).to include(candidate_count: 0, filtered_count: 0, result_count: 0)
  end
end
