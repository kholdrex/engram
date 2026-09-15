# frozen_string_literal: true

# Integration coverage for the real Postgres + pgvector adapter. Tagged :integration so
# it is skipped by the default (offline) suite. Run with a database:
#
#   DATABASE_URL=postgres://postgres:postgres@localhost:5432/engram_test \
#     bundle exec rspec --tag integration
#
# Requires the `integration` bundle group (activerecord, pg, neighbor).

deps_available =
  begin
    require "active_record"
    require "pg"
    require "neighbor"
    true
  rescue LoadError
    false
  end

if deps_available
  RSpec.describe "Engram::Adapters::PgvectorStore (integration)", :integration do
    subject(:store) { Engram::Adapters::PgvectorStore.new }

    before(:all) do
      ActiveRecord::Base.establish_connection(
        ENV.fetch("DATABASE_URL", "postgres://postgres:postgres@localhost:5432/engram_test")
      )
      conn = ActiveRecord::Base.connection
      conn.enable_extension("vector") unless conn.extension_enabled?("vector")
      conn.create_table(:engram_memories, force: true) do |t|
        t.string :scope, null: false
        t.text :content, null: false
        t.string :kind, null: false, default: "semantic"
        t.float :importance, null: false, default: 1.0
        t.jsonb :metadata, null: false, default: {}
        t.column :embedding, "vector(3)"
        t.datetime :last_accessed_at
        t.datetime :expires_at
        t.timestamps
      end

      unless defined?(Engram::MemoryRecord)
        model = Class.new(ActiveRecord::Base) do
          self.table_name = "engram_memories"
          has_neighbors :embedding
        end
        Engram.const_set(:MemoryRecord, model)
      end
      Engram::MemoryRecord.reset_column_information
    end

    after(:all) do
      ActiveRecord::Base.connection.drop_table(:engram_memories, if_exists: true)
    end

    before { Engram::MemoryRecord.delete_all }

    it "filters expiry in SQL before the limit and retains expired rows for inspection" do
      now = Time.utc(2026, 9, 15, 12)
      allow(Time).to receive(:now).and_return(now)
      expired = store.add(rec("expired", embedding: [1.0, 0.0, 0.0]).with(expires_at: now))
      future = store.add(rec("future", embedding: [0.9, 0.1, 0.0]).with(expires_at: now + 1))
      permanent = store.add(rec("permanent", embedding: [0.8, 0.2, 0.0]))
      store.add(rec("other tenant", embedding: [1.0, 0.0, 0.0], scope: "u:2"))

      expect(store.search(embedding: [1.0, 0.0, 0.0], scope: "u:1", limit: 1).map(&:id)).to eq([future.id])
      expect(store.all(scope: "u:1").map(&:id)).to eq([expired.id, future.id, permanent.id])
      expect(store.all(scope: "u:1").first.expires_at).to eq(now)
      allow(Time).to receive(:now).and_return(now + 1)
      expect(store.search(embedding: [1.0, 0.0, 0.0], scope: "u:1", limit: 1).map(&:id)).to eq([permanent.id])
    end

    it "persists changes to expiry without modifying another tenant's memory" do
      record = store.add(rec("trial", embedding: [1.0, 0.0, 0.0]).with(expires_at: Time.now - 1))
      expect { store.update(scope: "u:2", id: record.id, record: record.with(scope: "u:2", expires_at: nil)) }
        .to raise_error(Engram::Error, /no memory/)
      expect(store.all(scope: "u:1").first).to be_expired

      updated = store.update(scope: "u:1", id: record.id, record: record.with(expires_at: nil))
      expect(updated.expires_at).to be_nil
      expect(store.search(embedding: [1.0, 0.0, 0.0], scope: "u:1", limit: 1).map(&:id)).to eq([record.id])
    end

    it "accepts Rails time-zone deadlines through the public facade" do
      deadline = ActiveSupport::TimeZone["Kyiv"].local(2030, 1, 1, 12)
      memory = Engram::Memory.new(scope: "u:1", store: store,
        embedder: Engram::Adapters::NullEmbedder.new(dimensions: 3))
      stored = memory.add("trial", expires_at: deadline)

      expect(stored.expires_at).to eq(deadline.utc)
      expect(memory.recall("trial").map(&:id)).to eq([stored.id])
    end

    it "cleans up expired rows in batches with a dry run and tenant isolation" do
      now = Time.utc(2026, 9, 15, 12)
      allow(Time).to receive(:now).and_return(now)
      5.times { store.add(rec("expired", embedding: [1.0, 0.0, 0.0]).with(expires_at: now)) }
      permanent = store.add(rec("permanent", embedding: [1.0, 0.0, 0.0]))
      future = store.add(rec("future", embedding: [1.0, 0.0, 0.0]).with(expires_at: now + 1))
      other = store.add(rec("other", embedding: [1.0, 0.0, 0.0], scope: "u:2").with(expires_at: now))
      memory = Engram::Memory.new(scope: "u:1", store: store)

      expect(store).not_to receive(:all)
      expect(memory.forget_expired(batch_size: 2, dry_run: true)).to eq(matched: 5, deleted: 0, dry_run: true)
      expect(Engram::MemoryRecord.count).to eq(8)
      expect(memory.forget_expired(batch_size: 2)).to eq(matched: 5, deleted: 5, dry_run: false)
      expect(Engram::MemoryRecord.order(:id).pluck(:id)).to eq([permanent.id, future.id, other.id])
      expect(memory.forget_expired).to eq(matched: 0, deleted: 0, dry_run: false)
    end

    it "rechecks deadlines and scopes in the delete statement after a concurrent update" do
      now = Time.now
      expired = store.add(rec("expired", embedding: [1.0, 0.0, 0.0]).with(expires_at: now))
      extended = store.add(rec("extended", embedding: [1.0, 0.0, 0.0]).with(expires_at: now))
      cleared = store.add(rec("cleared", embedding: [1.0, 0.0, 0.0]).with(expires_at: now))
      other = store.add(rec("other", embedding: [1.0, 0.0, 0.0], scope: "u:2").with(expires_at: now))
      ids = store.expired_ids(scope: "u:1", at: now, limit: 10)
      writer = Engram::Adapters::PgvectorStore.new
      writer.update(scope: "u:1", id: extended.id, record: extended.with(expires_at: now + 60))
      writer.update(scope: "u:1", id: cleared.id, record: cleared.with(expires_at: nil))

      expect(store.delete_expired(scope: "u:1", ids: ids + [other.id], at: now)).to eq(1)
      expect(Engram::MemoryRecord.exists?(expired.id)).to be(false)
      expect(Engram::MemoryRecord.order(:id).pluck(:id)).to eq([extended.id, cleared.id, other.id])
    end

    it "applies bounded, thresholded recall through the production adapter" do
      store.add(rec("relevant preference", embedding: [1.0, 0.0, 0.0], kind: :preference))
      store.add(rec("unrelated preference", embedding: [0.0, 1.0, 0.0], kind: :preference))
      store.add(rec("other tenant", embedding: [1.0, 0.0, 0.0], scope: "u:2", kind: :preference))
      store.add(rec("relevant fact", embedding: [1.0, 0.0, 0.0]))
      embedder = Object.new
      def embedder.embed(_text)
        [1.0, 0.0, 0.0]
      end
      memory = Engram::Memory.new(scope: "u:1", store: store, embedder: embedder)

      records = memory.recall("q", kinds: [:preference], min_similarity: 0.5)
      expect(records.map(&:content)).to eq(["relevant preference"])
      prompt = memory.inject_into("P", query: "q", kinds: [:preference], min_similarity: 0.5, max_bytes: 200)
      expect(prompt).to include("relevant preference")
      expect(prompt).not_to include("unrelated preference", "other tenant", "relevant fact")
      expect(prompt.bytesize - 1).to be <= 200
      expect(memory.inject_into("P", query: "q", max_bytes: 1)).to eq("P")
    end

    def rec(content, embedding:, scope: "u:1", kind: :fact, metadata: {})
      Engram::Record.new(
        content: content,
        scope: scope,
        embedding: embedding,
        kind: kind,
        metadata: metadata
      )
    end

    def embedding_metadata(model: "model-a", dimensions: 3)
      Engram::EmbeddingMetadata.build(
        adapter: "test-adapter",
        provider: "test",
        model: model,
        dimensions: dimensions
      )
    end

    def metadata(model: "model-a", dimensions: 3)
      Engram::EmbeddingMetadata.merge({}, embedding_metadata(model: model, dimensions: dimensions))
    end

    it "persists a record and assigns an id" do
      stored = store.add(rec("plan is Pro", embedding: [1.0, 0.0, 0.0]))
      expect(stored.id).not_to be_nil
      expect(Engram::MemoryRecord.count).to eq(1)
    end

    it "round-trips versioned provenance metadata" do
      provenance = Engram::Provenance.new(
        sources: [
          Engram::Provenance::Source.new(
            source_id: "conversation:42",
            source_type: "conversation",
            message_index: 1,
            role: "user",
            spans: [Engram::Provenance::Span.new(start_offset: 0, end_offset: 4)],
            alignment: :exact
          )
        ],
        extractor: Engram::Provenance::Extractor.new(name: "test-extractor", model: "test-model"),
        confidence: 0.9
      )
      record_metadata = Engram::Provenance.attach({"host" => "value"}, provenance)

      stored = store.add(rec("tea", embedding: [1.0, 0.0, 0.0], metadata: record_metadata))
      loaded = store.all(scope: "u:1").first

      expect(Engram::Provenance.extract(stored.metadata)).to eq(provenance)
      expect(Engram::Provenance.extract(loaded.metadata)).to eq(provenance)
      expect(loaded.metadata["host"]).to eq("value")
    end

    it "returns nearest neighbours first, scoped to the owner" do
      store.add(rec("near", embedding: [1.0, 0.0, 0.0]))
      store.add(rec("far", embedding: [0.0, 1.0, 0.0]))
      store.add(rec("other owner", embedding: [1.0, 0.0, 0.0], scope: "u:2"))

      results = store.search(embedding: [1.0, 0.0, 0.0], scope: "u:1", limit: 5)
      expect(results.map(&:content)).to eq(["near", "far"])
    end

    it "raises when a pgvector row has conflicting embedding metadata" do
      store.add(rec("old model", embedding: [1.0, 0.0, 0.0], metadata: metadata(model: "model-a")))

      expect do
        store.search(
          embedding: [1.0, 0.0, 0.0],
          embedding_metadata: embedding_metadata(model: "model-b"),
          scope: "u:1",
          limit: 5
        )
      end.to raise_error(Engram::Error, /embedding metadata mismatch.*model/)
    end

    it "keeps legacy pgvector rows without embedding metadata searchable" do
      store.add(rec("legacy", embedding: [1.0, 0.0, 0.0]))

      results = store.search(
        embedding: [1.0, 0.0, 0.0],
        embedding_metadata: embedding_metadata(model: "model-b"),
        scope: "u:1",
        limit: 5
      )

      expect(results.map(&:content)).to eq(["legacy"])
    end

    it "filters by scope before nearest-neighbor ranking for adversarially similar records" do
      store.add(rec("mine", embedding: [1.0, 0.0, 0.0], scope: "u:1"))
      store.add(rec("theirs", embedding: [1.0, 0.0, 0.0], scope: "u:2"))

      results = store.search(embedding: [1.0, 0.0, 0.0], scope: "u:2", limit: 1)

      expect(results.map(&:content)).to eq(["theirs"])
    end

    it "treats scope prefixes as distinct owners" do
      store.add(rec("short scope", embedding: [1.0, 0.0, 0.0], scope: "user:4"))
      store.add(rec("long scope", embedding: [1.0, 0.0, 0.0], scope: "user:42"))

      expect(store.all(scope: "user:4").map(&:content)).to eq(["short scope"])
      expect(store.search(embedding: [1.0, 0.0, 0.0], scope: "user:42", limit: 5).map(&:content))
        .to eq(["long scope"])
    end

    it "treats blank scope as explicit and nil search scope as non-wildcard" do
      store.add(rec("blank scope", embedding: [1.0, 0.0, 0.0], scope: ""))
      store.add(rec("named scope", embedding: [1.0, 0.0, 0.0], scope: "u:1"))

      expect(store.all(scope: "").map(&:content)).to eq(["blank scope"])
      expect(store.search(embedding: [1.0, 0.0, 0.0], scope: "", limit: 5).map(&:content))
        .to eq(["blank scope"])
      expect(store.all(scope: nil)).to be_empty
      expect(store.search(embedding: [1.0, 0.0, 0.0], scope: nil, limit: 5)).to be_empty
    end

    it "rejects nil scope persistence because the pgvector schema requires a scope" do
      expect { store.add(rec("nil scope", embedding: [1.0, 0.0, 0.0], scope: nil)) }
        .to raise_error(Engram::Error, "memory scope cannot be nil")
    end

    it "filters nearest neighbours by memory kind" do
      store.add(rec("prefers concise answers", embedding: [1.0, 0.0, 0.0], kind: :preference))
      store.add(rec("billing tier is Pro", embedding: [1.0, 0.0, 0.0], kind: :fact))

      results = store.search(embedding: [1.0, 0.0, 0.0], scope: "u:1", limit: 5, kinds: [:preference])

      expect(results.map(&:content)).to eq(["prefers concise answers"])
    end

    it "includes legacy semantic rows when filtering for facts" do
      Engram::MemoryRecord.create!(
        content: "billing tier is Pro",
        scope: "u:1",
        kind: "semantic",
        importance: 1.0,
        metadata: {},
        embedding: [1.0, 0.0, 0.0]
      )

      results = store.search(embedding: [1.0, 0.0, 0.0], scope: "u:1", limit: 5, kinds: [:fact])

      expect(results.map(&:content)).to eq(["billing tier is Pro"])
    end

    it "updates an existing record by id" do
      stored = store.add(rec("plan is Free", embedding: [1.0, 0.0, 0.0]))
      updated = store.update(scope: "u:1", id: stored.id,
        record: rec("plan is Pro", embedding: [0.0, 0.0, 1.0]))

      expect(updated).to be_a(Engram::Record)
      expect(updated.content).to eq("plan is Pro")
      expect(store.all(scope: "u:1").map(&:content)).to eq(["plan is Pro"])
    end

    it "supports batched scope reads with stable ordering" do
      first_record = store.add(rec("third", embedding: [1.0, 0.0, 0.0]))
      second_record = store.add(rec("first", embedding: [1.0, 0.0, 0.0]))
      third_record = store.add(rec("second", embedding: [1.0, 0.0, 0.0]))

      expect(store.all(scope: "u:1", limit: 2).map(&:content)).to eq(["third", "first"])
      expect(store.all(scope: "u:1", offset: 1, limit: 2).map(&:content)).to eq(["first", "second"])
      expect(store.all(scope: "u:1", after_id: third_record.id).map(&:content)).to be_empty
      expect(store.all(scope: "u:1", after_id: first_record.id).map(&:content)).to eq(["first", "second"])
      expect(store.all(scope: "u:1", after_id: second_record.id).map(&:content)).to eq(["second"])
    end

    it "returns only requested ids that exist in the scope" do
      mine = store.add(rec("mine", embedding: [1.0, 0.0, 0.0], scope: "u:1"))
      theirs = store.add(rec("theirs", embedding: [1.0, 0.0, 0.0], scope: "u:2"))

      expect(store.existing_ids(scope: "u:1", ids: [theirs.id, mine.id, -1])).to eq([mine.id])
    end

    it "preserves requested string ids after Active Record casts them" do
      mine = store.add(rec("mine", embedding: [1.0, 0.0, 0.0], scope: "u:1"))

      expect(store.existing_ids(scope: "u:1", ids: [mine.id.to_s])).to eq([mine.id.to_s])
    end

    it "does not confirm two requested representations of the same persisted id" do
      mine = store.add(rec("mine", embedding: [1.0, 0.0, 0.0], scope: "u:1"))

      expect(store.existing_ids(scope: "u:1", ids: [mine.id.to_s, mine.id])).to eq([mine.id.to_s])
    end

    it "deletes a record by id" do
      stored = store.add(rec("temp", embedding: [1.0, 0.0, 0.0]))
      expect(store.delete(scope: "u:1", id: stored.id)).to eq(1)
      expect(store.delete(scope: "u:1", id: stored.id)).to eq(0)
      expect(store.all(scope: "u:1")).to be_empty
    end

    it "does not mutate records through another scope or move them across scopes" do
      stored = store.add(rec("secret", scope: "u:2", embedding: [1.0, 0.0, 0.0]))

      expect {
        store.update(scope: "u:1", id: stored.id,
          record: rec("stolen", scope: "u:1", embedding: [0.0, 1.0, 0.0]))
      }.to raise_error(Engram::Error)
      expect(store.delete(scope: "u:1", id: stored.id)).to eq(0)
      expect(store.touch(scope: "u:1", id: stored.id, at: Time.at(0))).to eq(0)
      expect {
        store.update(scope: "u:2", id: stored.id,
          record: rec("moved", scope: "u:1", embedding: [0.0, 1.0, 0.0]))
      }.to raise_error(Engram::Error, /scope/)

      record = store.all(scope: "u:2").first
      expect(record.content).to eq("secret")
      expect(record.last_accessed_at).to be_nil
    end

    it "returns affected-row counts when touching records" do
      stored = store.add(rec("temp", embedding: [1.0, 0.0, 0.0]))

      expect(store.touch(scope: "u:1", id: stored.id, at: Time.at(0))).to eq(1)
      expect(store.touch(scope: "u:1", id: -1, at: Time.at(0))).to eq(0)
    end
  end
end
