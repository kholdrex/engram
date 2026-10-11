# frozen_string_literal: true

RSpec.describe Engram::UseCases::Update do
  let(:store) { Engram::Adapters::InMemoryStore.new }
  let(:embedder) { Engram::Adapters::NullEmbedder.new }
  let(:memory) { Engram::Memory.new(scope: "u:1", store: store, embedder: embedder) }
  let(:deadline) { Time.utc(2030, 1, 1) }
  let!(:original) do
    memory.add("I live in Paris", kind: :fact, importance: 0.7,
      metadata: {"old" => {"tags" => ["city"]}}, expires_at: deadline)
  end

  def provenance_payload
    Engram::Provenance.new(
      sources: [Engram::Provenance::Source.new(source_id: "message:1", source_type: "message", message_index: 0, role: "user",
        spans: [Engram::Provenance::Span.new(start_offset: 0, end_offset: 4)], alignment: :exact)],
      extractor: Engram::Provenance::Extractor.new(name: "host", model: "model-1"), confidence: 0.9
    ).to_h.merge("extension" => {"evidence" => [1, "kept"]})
  end

  def add_provenance(payload = provenance_payload)
    original.metadata["_engram"]["provenance"] = payload
  end

  def current
    store.find(scope: "u:1", id: original.id)
  end

  it "returns the actual stored record with the same id" do
    updated = memory.update(id: original.id, content: "I moved to Berlin")
    expect(updated).to equal(current)
    expect(updated.id).to eq(original.id)
    expect(updated.content).to eq("I moved to Berlin")
    expect(updated.embedding).to eq(embedder.embed("I moved to Berlin"))
  end

  {
    content: "I moved to Berlin", kind: " PREFERENCE ", importance: -2,
    metadata: {"new" => [1]}, expires_at: Time.utc(2031, 1, 1)
  }.each do |field, value|
    it "updates #{field} and preserves omitted attributes" do
      updated = memory.update(id: original.id, **{field => value})
      expected = (field == :kind) ? :preference : value
      actual = (field == :metadata) ? updated.metadata.except("_engram") : updated.public_send(field)
      expect(actual).to eq(expected)
      (%i[content kind importance metadata expires_at] - [field]).each do |omitted|
        expect(updated.public_send(omitted)).to eq(original.public_send(omitted))
      end
    end
  end

  it "normalizes the legacy kind and accepts finite importance without a range limit" do
    expect(memory.update(id: original.id, kind: :semantic).kind).to eq(:fact)
    expect(memory.update(id: original.id, importance: 42.5).importance).to eq(42.5)
  end

  it "clears application metadata and expiry explicitly while preserving reserved siblings" do
    original.metadata["_engram"]["other_schema"] = {"v" => 2}
    updated = memory.update(id: original.id, metadata: {}, expires_at: nil)
    expect(updated.metadata).to eq("_engram" => original.metadata["_engram"])
    expect(updated.expires_at).to be_nil
  end

  it "can correct an expired record and restore it to recall" do
    memory.update(id: original.id, expires_at: Time.now - 60)
    expect(memory.recall(original.content)).to be_empty
    expect(memory.update(id: original.id, expires_at: nil).expires_at).to be_nil
    expect(memory.recall(original.content).map(&:id)).to eq([original.id])
  end

  invalid_attributes = [
    {}, {content: nil}, {content: ""}, {content: " \n"}, {content: 1}, {content: "\xFF".b.force_encoding("UTF-8")},
    {kind: nil}, {kind: :unknown}, {importance: nil}, {importance: "1"}, {importance: Rational(1, 2)},
    {importance: Float::NAN}, {importance: Float::INFINITY}, {importance: -Float::INFINITY},
    {metadata: nil}, {metadata: []}, {metadata: {"_engram" => {}}}, {metadata: {_engram: {}}},
    {expires_at: "tomorrow"}, {expires_at: 1}
  ]
  invalid_attributes.each do |attributes|
    it "rejects invalid attributes #{attributes.inspect} before any collaborators run" do
      Engram.config.before_persist = ->(_) { raise "hook called" }
      Engram.config.persistence_policy = ->(_) { raise "policy called" }
      expect(store).not_to receive(:find)
      expect(store).not_to receive(:all)
      expect(store).not_to receive(:update)
      expect(embedder).not_to receive(:embed)
      expect(Engram::Instrumentation).not_to receive(:instrument)
      expect { memory.update(id: original.id, **attributes) }.to raise_error(ArgumentError)
    end
  end

  [nil, "", " \t", "\xFF".b.force_encoding("UTF-8"), 1.2, :id, [], true].each do |id|
    it "rejects invalid id #{id.inspect} before lookup" do
      expect(store).not_to receive(:find)
      expect(Engram::Instrumentation).not_to receive(:instrument)
      expect { memory.update(id: id, importance: 1) }.to raise_error(ArgumentError)
    end
  end

  it "accepts opaque nonblank String ids without coercing them" do
    expect(store).to receive(:find).with(scope: "u:1", id: "abc")
    expect { memory.update(id: "abc", importance: 1) }.to raise_error(Engram::MemoryNotFoundError)
  end

  it "raises the same not-found error for absent and other-scope ids" do
    other = store.add(original.with(scope: "u:2", id: nil))
    [999, other.id].each do |id|
      expect { memory.update(id: id, content: "Berlin") }.to raise_error(Engram::MemoryNotFoundError)
    end
  end

  it "treats an out-of-scope result from a faulty store as missing" do
    allow(store).to receive(:find).and_return(original.with(scope: "u:2"))
    expect(embedder).not_to receive(:embed)
    expect { memory.update(id: original.id, content: "Berlin") }.to raise_error(Engram::MemoryNotFoundError)
  end

  it "rejects policy-filtered edits without embedding or writing" do
    expect(embedder).not_to receive(:embed)
    expect(store).not_to receive(:update)
    expect(memory.update(id: original.id, content: "User API key is fake-token-abcdef")).to be_nil
    expect(current).to equal(original)
  end

  it "authorizes the original before content edits can strip ungrounded provenance" do
    payload = provenance_payload
    payload["sources"][0]["alignment"] = "ungrounded"
    add_provenance(payload)
    Engram.config.before_persist = ->(_) { raise "hook called" }
    expect(embedder).not_to receive(:embed)
    expect(memory.update(id: original.id, content: "Berlin")).to be_nil
    expect(current).to equal(original)
  end

  it "authorizes the original, while allowing correction of previously stored secrets" do
    stored = store.add(original.with(content: "User API key is fake-token-abcdef", id: nil))
    expect(memory.update(id: stored.id, content: "User lives in Berlin").content).to eq("User lives in Berlin")
  end

  it "runs hooks even when a supplied value equals its stored value" do
    calls = []
    Engram.config.before_persist = lambda do |record|
      calls << record
      record
    end
    memory.update(id: original.id, content: original.content)
    expect(calls.length).to eq(1)
  end

  it "embeds only final redacted text" do
    Engram.config.before_persist = ->(record) { record.with(content: record.content.gsub("private", "redacted")) }
    expect(embedder).to receive(:embed).once.with("redacted text").and_call_original
    expect(memory.update(id: original.id, content: "private text").content).to eq("redacted text")
  end

  it "keeps full provenance including extensions on metadata-only edits" do
    add_provenance
    expect(embedder).not_to receive(:embed)
    expect(memory.update(id: original.id, metadata: {}).metadata.dig("_engram", "provenance")).to eq(provenance_payload)
  end

  it "drops provenance for caller, hook, and policy content changes" do
    [:caller, :hook, :policy].each do |stage|
      stored = store.add(original.with(id: nil, metadata: original.metadata.merge("_engram" => {"provenance" => provenance_payload})))
      Engram.config.before_persist = (stage == :hook) ? ->(record) { record.with(content: "Berlin") } : nil
      Engram.config.persistence_policy = (stage == :policy) ? ->(record) { record.with(content: "Berlin") } : nil
      attributes = (stage == :caller) ? {content: "Berlin"} : {importance: 2}
      updated = memory.update(id: stored.id, **attributes)
      expect(updated.content).to eq("Berlin")
      expect(updated.metadata.fetch("_engram")).not_to have_key("provenance")
    end
  end

  it "never restores provenance when a later stage restores the original text" do
    add_provenance
    Engram.config.before_persist = ->(record) { record.with(content: "Berlin") }
    Engram.config.persistence_policy = ->(record) { record.with(content: original.content) }
    expect(embedder).not_to receive(:embed)
    updated = memory.update(id: original.id, importance: 2)
    expect(updated.content).to eq(original.content)
    expect(updated.provenance).to be_nil
    expect(updated.embedding).to eq(original.embedding)
  end

  it "keeps provenance invalidated when the hook reverses a caller edit" do
    add_provenance
    Engram.config.before_persist = ->(record) { record.with(content: original.content) }
    expect(memory.update(id: original.id, content: "Berlin").provenance).to be_nil
  end

  [{"version" => 99}, {"version" => 1, "sources" => []}].each do |payload|
    it "fails closed on stored invalid provenance #{payload.inspect} even when changing content" do
      add_provenance(payload)
      Engram.config.before_persist = ->(_) { raise "hook called" }
      expect(embedder).not_to receive(:embed)
      expect { memory.update(id: original.id, content: "Berlin") }.to raise_error(Engram::Error, /provenance/)
      expect(current).to equal(original)
    end
  end

  it "prevents hooks from adding, removing, or changing provenance" do
    [nil, {}, provenance_payload.merge("confidence" => 0.5)].each do |changed|
      add_provenance
      Engram.config.before_persist = lambda do |record|
        if changed
          record.metadata["_engram"]["provenance"] = changed
        else
          record.metadata["_engram"].delete("provenance")
        end
        record
      end
      expect { memory.update(id: original.id, importance: 2) }.to raise_error(Engram::Error, /provenance/)
      expect(original.metadata.dig("_engram", "provenance")).to eq(provenance_payload)
    end
    original.metadata["_engram"].delete("provenance")
    Engram.config.before_persist = ->(record) { record.with(metadata: {"_engram" => {"provenance" => provenance_payload}}) }
    expect { memory.update(id: original.id, importance: 2) }.to raise_error(Engram::Error, /provenance trust/)
  end

  it "rejects policy provenance changes as well" do
    add_provenance
    Engram.config.persistence_policy = ->(record) { record.with(metadata: {}) }
    expect { memory.update(id: original.id, importance: 2) }.to raise_error(Engram::Error, /provenance trust/)
  end

  it "keeps stored embedding metadata when the configured embedder changes" do
    changed_embedder = double("new embedder")
    expect(changed_embedder).not_to receive(:embed)
    expect(changed_embedder).not_to receive(:embedding_metadata)
    changed_memory = Engram::Memory.new(scope: "u:1", store: store, embedder: changed_embedder)
    updated = changed_memory.update(id: original.id, metadata: {})
    expect(updated.embedding).to eq(original.embedding)
    expect(updated.metadata["_engram"]["embedding"]).to eq(original.metadata["_engram"]["embedding"])
  end

  it "ignores hook embedding replacements when retaining the stored vector" do
    Engram.config.before_persist = lambda do |record|
      record.metadata["_engram"]["embedding"] = {"model" => "wrong"}
      record.with(embedding: [99.0])
    end
    updated = memory.update(id: original.id, importance: 2)
    expect(updated.embedding).to eq(original.embedding)
    expect(updated.metadata["_engram"]["embedding"]).to eq(original.metadata["_engram"]["embedding"])
  end

  it "embeds a record without a stored vector even on a metadata-only edit" do
    stored = store.add(original.with(id: nil, embedding: nil))
    expect(embedder).to receive(:embed).once.with(original.content).and_call_original
    updated = memory.update(id: stored.id, metadata: {})
    expect(updated.embedding).not_to be_nil
    expect(updated.metadata.dig("_engram", "embedding", "model")).to eq("null-embedder-v1")
  end

  it "removes obsolete embedding metadata when the new embedder supplies none" do
    changed_embedder = double("bare embedder", embed: [1.0, 2.0])
    changed_memory = Engram::Memory.new(scope: "u:1", store: store, embedder: changed_embedder)
    updated = changed_memory.update(id: original.id, content: "Berlin")
    expect(updated.embedding).to eq([1.0, 2.0])
    expect(updated.metadata.fetch("_engram")).not_to have_key("embedding")
  end

  it "accepts stored timestamps that are Time subclasses, such as Rails time zones" do
    zoned = Class.new(Time)
    stored = store.find(scope: "u:1", id: original.id)
    allow(store).to receive(:find).and_return(stored.with(
      created_at: zoned.at(original.created_at.to_r),
      last_accessed_at: zoned.at(0)
    ))

    updated = memory.update(id: original.id, importance: 2)

    expect(updated.importance).to eq(2)
    expect(updated.created_at).to eq(original.created_at)
  end

  it "preserves timestamps including a recall touch during preparation" do
    accessed = Time.utc(2026, 1, 1)
    Engram.config.before_persist = lambda do |record|
      store.touch(scope: "u:1", id: original.id, at: accessed)
      record.with(created_at: Time.now + 60, last_accessed_at: Time.now + 60)
    end
    updated = memory.update(id: original.id, importance: 2)
    expect(updated.created_at).to eq(original.created_at)
    expect(updated.last_accessed_at).to eq(accessed)
  end

  it "detaches metadata containers and core strings while keeping opaque leaf identity on rejection" do
    opaque = Object.new
    original.metadata["opaque"] = opaque
    Engram.config.before_persist = lambda do |record|
      expect(record.metadata["opaque"]).to equal(opaque)
      record.metadata["old"]["tags"] << "changed"
      record.content.replace("Berlin")
      nil
    end
    expect(embedder).not_to receive(:embed)
    expect(memory.update(id: original.id, importance: 2)).to be_nil
    expect(original.metadata["old"]["tags"]).to eq(["city"])
    expect(original.content).to eq("I live in Paris")
    expect(current).to equal(original)
  end

  it "does not leak in-place policy mutations when rejected" do
    Engram.config.persistence_policy = lambda do |record|
      record.metadata["old"]["tags"].clear
      nil
    end
    expect(embedder).not_to receive(:embed)
    expect(memory.update(id: original.id, importance: 2)).to be_nil
    expect(original.metadata["old"]["tags"]).to eq(["city"])
  end

  it "falls back to all for a store without find" do
    legacy = double("legacy store")
    expect(legacy).to receive(:all).with(scope: "u:1").and_return([original])
    expect(legacy).to receive(:update).with(scope: "u:1", id: original.id, record: an_instance_of(Engram::Record)) do |**args|
      store.update(**args)
    end
    legacy_memory = Engram::Memory.new(scope: "u:1", store: legacy, embedder: embedder)
    expect(legacy_memory.update(id: original.id, importance: 2).importance).to eq(2)
  end

  it "rejects reserved keys hidden by a metadata Hash subclass before lookup" do
    metadata = Class.new(Hash) do
      def key?(_key) = false
      def each_pair = yield(:safe, true)
    end.new
    metadata[:_engram] = {}
    expect(store).not_to receive(:find)
    expect { memory.update(id: original.id, metadata: metadata) }.to raise_error(ArgumentError)
  end

  it "detaches subclassed metadata containers before hooks can mutate them" do
    nested = Class.new(Hash).new
    tags = Class.new(Array).new(["city"])
    nested["tags"] = tags
    original.metadata["old"] = nested
    Engram.config.before_persist = lambda do |record|
      record.metadata["old"]["tags"].clear
      record.metadata["old"]["new"] = true
      nil
    end
    expect(memory.update(id: original.id, importance: 2)).to be_nil
    expect(nested).to eq("tags" => ["city"])
  end

  it "isolates authorization mutations and stops before write transformations on denial" do
    policy = double("policy")
    expect(policy).to receive(:allow_destructive?) do |record|
      expect(record.content).to eq(original.content)
      record.metadata["old"]["tags"].clear
      false
    end
    expect(policy).not_to receive(:call)
    expect(embedder).not_to receive(:embed)
    Engram.config.persistence_policy = policy
    Engram.config.before_persist = ->(_) { raise "hook called" }
    expect(memory.update(id: original.id, content: "Berlin")).to be_nil
    expect(original.metadata["old"]["tags"]).to eq(["city"])
  end

  it "preserves absent embedding metadata when retaining a legacy vector" do
    original.metadata.delete("_engram")
    expect(embedder).not_to receive(:embed)
    expect(embedder).not_to receive(:embedding_metadata)
    expect(memory.update(id: original.id, importance: 2).metadata).to eq(original.metadata)
  end

  it "attaches current embedding metadata to a newly generated vector" do
    changed_embedder = double("new embedder", embed: [1.0, 2.0], embedding_metadata: {model: "new-model", dimensions: 2})
    changed_memory = Engram::Memory.new(scope: "u:1", store: store, embedder: changed_embedder)
    updated = changed_memory.update(id: original.id, content: "Berlin")
    expect(updated.embedding).to eq([1.0, 2.0])
    expect(updated.metadata.dig("_engram", "embedding")).to include("model" => "new-model", "dimensions" => 2)
  end

  it "propagates callback and embedding exceptions without writing" do
    expect(store).not_to receive(:update)
    Engram.config.before_persist = ->(_) { raise IOError, "hook failed" }
    expect { memory.update(id: original.id, content: "Berlin") }.to raise_error(IOError, "hook failed")
    Engram.config.before_persist = nil
    allow(embedder).to receive(:embed).and_raise(IOError, "embed failed")
    expect { memory.update(id: original.id, content: "Berlin") }.to raise_error(IOError, "embed failed")
    expect(current).to equal(original)
  end

  it "falls back when find raises NotImplementedError" do
    allow(store).to receive(:find).and_raise(NotImplementedError)
    expect(store).to receive(:all).with(scope: "u:1").and_call_original
    expect(memory.update(id: original.id, importance: 2).importance).to eq(2)
  end

  it "does not fall back on a legitimate nil or a lookup failure" do
    expect(store).not_to receive(:all)
    allow(store).to receive(:find).and_return(nil)
    expect { memory.update(id: original.id, importance: 2) }.to raise_error(Engram::MemoryNotFoundError)
    allow(store).to receive(:find).and_raise(IOError, "offline")
    expect { memory.update(id: original.id, importance: 2) }.to raise_error(IOError, "offline")
  end

  it "propagates write errors without resurrecting a concurrently deleted record" do
    Engram.config.before_persist = lambda do |record|
      store.delete(scope: "u:1", id: original.id)
      record
    end
    expect { memory.update(id: original.id, importance: 2) }.to raise_error(Engram::Error)
    expect(current).to be_nil
  end

  it "fails closed on hook identity or scope changes before embedding" do
    expect(embedder).not_to receive(:embed)
    [{id: 999}, {scope: "u:2"}].each do |attributes|
      Engram.config.before_persist = ->(record) { record.with(**attributes) }
      expect { memory.update(id: original.id, content: "Berlin") }.to raise_error(Engram::Error, /identity or scope/)
    end
  end
end
