# frozen_string_literal: true

RSpec.describe Engram::Memory do
  it "validates expiry before embedding or persistence" do
    expect(embedder).not_to receive(:embed)
    expect(store).not_to receive(:add)

    expect { memory.add("trial", expires_at: "tomorrow") }.to raise_error(ArgumentError, /expires_at/)
  end

  it "keeps expiry through persistence transformations and embedding rebuilds" do
    deadline = Time.now + 60
    Engram.config.before_persist = ->(record) { record.with(content: "redacted") }
    stored = memory.add("trial", expires_at: deadline)
    memory.rebuild_embeddings(stale_only: false)

    expect(stored.content).to eq("redacted")
    expect(memory.all.first.expires_at).to eq(deadline)
  end

  it "stops recalling and injecting expired memories without deleting them" do
    now = Time.utc(2026, 9, 15, 12)
    allow(Time).to receive(:now).and_return(now)
    stored = memory.add("Trial active", expires_at: now + 1)
    expect(memory.recall("Trial active")).to eq([stored])

    allow(Time).to receive(:now).and_return(now + 1)
    expect(memory.recall("Trial active")).to eq([])
    expect(memory.inject_into("P", query: "Trial active")).to eq("P")
    expect(memory.all).to eq([stored])
    expect(memory.forget(id: stored.id)).to eq(1)
  end

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

  it "rejects scalar reserved metadata and preserves sibling Engram schemas" do
    expect do
      memory.add("hello", metadata: {"_engram" => "user data"})
    end.to raise_error(Engram::Error, /reserved for Engram embedding metadata/)

    record = memory.add("hello", metadata: {
      "_engram" => {"future_schema" => {"enabled" => true}},
      :_engram => {other_schema: {version: 1}}
    })

    expect(record.metadata.dig("_engram", "future_schema")).to eq("enabled" => true)
    expect(record.metadata.dig("_engram", "other_schema")).to eq("version" => 1)
  end

  it "recalls legacy records with scalar reserved metadata as metadata-free records" do
    store.add(Engram::Record.new(
      content: "legacy fact",
      scope: "user:1",
      embedding: embedder.embed("legacy fact"),
      metadata: {"_engram" => "legacy user data"}
    ))

    expect(memory.recall("legacy fact", limit: 1).map(&:content)).to eq(["legacy fact"])
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

  it "uses configured recall and injection controls with explicit per-call overrides" do
    allow(embedder).to receive(:embed).and_return([1.0, 0.0])
    stored = store.add(Engram::Record.new(content: "orthogonal", scope: "user:1", embedding: [0.0, 1.0]))
    Engram.config.recall_min_similarity = 0.5
    Engram.config.injection_max_bytes = 1

    expect(memory.recall("q")).to eq([])
    expect(memory.recall("q", min_similarity: nil)).to eq([stored])
    expect(memory.inject_into("P", query: "q", min_similarity: nil)).to eq("P")
    expect(memory.inject_into("P", query: "q", min_similarity: nil, max_bytes: nil)).to include("orthogonal")
  end

  it "validates the injection budget before embedding or searching" do
    expect(embedder).not_to receive(:embed)
    expect(store).not_to receive(:search)

    expect { memory.inject_into("P", query: "q", max_bytes: -1) }.to raise_error(ArgumentError, /max_bytes/)
    expect(memory.inject_into("P", query: "q", max_bytes: 0)).to eq("P")
    expect(memory.inject_into("P", query: "q", limit: 0)).to eq("P")
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

  describe "#forget" do
    it "deletes one memory and stops recalling it" do
      deleted = memory.add("prefers tea")
      kept = memory.add("prefers short answers")

      expect(memory.forget(id: deleted.id)).to eq(1)
      expect(memory.all).to eq([kept])
      expect(memory.recall("prefers tea")).not_to include(deleted)
    end

    it "returns zero for missing memories and repeated deletions" do
      record = memory.add("prefers tea")

      expect(memory.forget(id: record.id)).to eq(1)
      expect(memory.forget(id: record.id)).to eq(0)
      expect(memory.forget(id: -1)).to eq(0)
    end

    it "cannot delete another owner's memory" do
      other = described_class.new(scope: "user:10", store: store, embedder: embedder)
      record = other.add("prefers tea")

      expect(memory.forget(id: record.id)).to eq(0)
      expect(other.all).to eq([record])
    end

    it "does not treat nil or blank scopes as wildcards" do
      record = memory.add("prefers tea")

      [nil, ""].each do |scope|
        other = described_class.new(scope: scope, store: store, embedder: embedder)
        expect(other.forget(id: record.id)).to eq(0)
      end
      expect(memory.all).to eq([record])
    end

    it "rejects non-scalar and blank ids before calling the store" do
      expect(store).not_to receive(:delete)
      invalid_ids = [nil, [], [1, 2], (1..2), {id: 1}, true, false, 1.0, :id, "", " \t\n", "\xFF".b.force_encoding("UTF-8")]

      invalid_ids.each do |id|
        expect { memory.forget(id: id) }.to raise_error(ArgumentError, /id/)
      end
    end

    it "passes string ids through to custom stores without coercion" do
      custom_store = double
      expect(custom_store).to receive(:delete).with(scope: "user:1", id: "memory:123").and_return(1)

      expect(described_class.new(scope: "user:1", store: custom_store).forget(id: "memory:123")).to eq(1)
    end

    it "deletes records even when their content and metadata would fail persistence checks" do
      record = store.add(Engram::Record.new(
        content: "User API key is fake-token-abcdef", scope: memory.scope,
        metadata: {"_engram" => "legacy metadata"}
      ))
      policy = double
      hook = double
      processed_turns = double
      Engram.config.persistence_policy = policy
      Engram.config.before_persist = hook
      Engram.config.processed_turns = processed_turns
      expect(policy).not_to receive(:call)
      expect(policy).not_to receive(:allow_destructive?)
      expect(hook).not_to receive(:call)
      expect(embedder).not_to receive(:embed)
      expect(store).not_to receive(:all)
      expect(store).not_to receive(:search)

      expect(memory.forget(id: record.id)).to eq(1)
    end

    it "propagates a store failure" do
      allow(store).to receive(:delete).and_raise(Engram::Error, "store unavailable")

      expect { memory.forget(id: 1) }.to raise_error(Engram::Error, "store unavailable")
    end
  end

  it "rebuilds embeddings through the Memory facade" do
    store.add(Engram::Record.new(content: "legacy", scope: "user:1", embedding: embedder.embed("legacy")))

    result = memory.rebuild_embeddings

    expect(result).to include(scope: "user:1", updated: 1, processed: 1, skipped: 0)
  end

  it "looks up memories from a source through the facade, bounded to the scope" do
    source = Engram::Provenance::Source.new(
      source_id: "conversation:42", source_type: "conversation", message_index: 0,
      role: "user", spans: [Engram::Provenance::Span.new(start_offset: 0, end_offset: 1)],
      alignment: :exact
    )
    provenance = Engram::Provenance.new(
      sources: [source],
      extractor: Engram::Provenance::Extractor.new(name: "host", model: "model-1"),
      confidence: 0.9
    )
    store.add(Engram::Record.new(content: "mine", scope: "user:1",
      embedding: embedder.embed("mine"), metadata: Engram::Provenance.attach({}, provenance)))
    store.add(Engram::Record.new(content: "theirs", scope: "user:2",
      embedding: embedder.embed("theirs"), metadata: Engram::Provenance.attach({}, provenance)))

    results = memory.memories_from_source(source_id: "conversation:42", source_type: "conversation")

    expect(results.map(&:content)).to eq(["mine"])
  end

  it "raises when the source lookup receives a blank identifier" do
    expect { memory.memories_from_source(source_id: "  ", source_type: "conversation") }
      .to raise_error(ArgumentError, /source_id/)
  end

  it "reports grounding coverage bound to the facade scope" do
    source = Engram::Provenance::Source.new(
      source_id: "conversation:42", source_type: "conversation", message_index: 0,
      role: "user", spans: [Engram::Provenance::Span.new(start_offset: 0, end_offset: 1)],
      alignment: :exact
    )
    provenance = Engram::Provenance.new(
      sources: [source],
      extractor: Engram::Provenance::Extractor.new(name: "host", model: "model-1"),
      confidence: 0.9
    )
    store.add(Engram::Record.new(content: "mine", scope: "user:1",
      embedding: embedder.embed("mine"), metadata: Engram::Provenance.attach({}, provenance)))
    store.add(Engram::Record.new(content: "theirs", scope: "user:2",
      embedding: embedder.embed("theirs")))

    expect(memory.grounding_report).to eq(
      exact: 1, normalized: 0, inferred: 0, ungrounded: 0, unattributed: 0, total: 1
    )
  end
end
