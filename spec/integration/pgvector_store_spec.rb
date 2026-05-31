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
        t.timestamps
      end

      unless defined?(Engram::MemoryRecord)
        model = Class.new(ActiveRecord::Base) do
          self.table_name = "engram_memories"
          has_neighbors :embedding
        end
        Engram.const_set(:MemoryRecord, model)
      end
    end

    after(:all) do
      ActiveRecord::Base.connection.drop_table(:engram_memories, if_exists: true)
    end

    before { Engram::MemoryRecord.delete_all }

    def rec(content, embedding:, scope: "u:1", kind: :fact)
      Engram::Record.new(content: content, scope: scope, embedding: embedding, kind: kind)
    end

    it "persists a record and assigns an id" do
      stored = store.add(rec("plan is Pro", embedding: [1.0, 0.0, 0.0]))
      expect(stored.id).not_to be_nil
      expect(Engram::MemoryRecord.count).to eq(1)
    end

    it "returns nearest neighbours first, scoped to the owner" do
      store.add(rec("near", embedding: [1.0, 0.0, 0.0]))
      store.add(rec("far", embedding: [0.0, 1.0, 0.0]))
      store.add(rec("other owner", embedding: [1.0, 0.0, 0.0], scope: "u:2"))

      results = store.search(embedding: [1.0, 0.0, 0.0], scope: "u:1", limit: 5)
      expect(results.map(&:content)).to eq(["near", "far"])
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
      store.update(id: stored.id, record: rec("plan is Pro", embedding: [0.0, 0.0, 1.0]))

      expect(store.all(scope: "u:1").map(&:content)).to eq(["plan is Pro"])
    end

    it "deletes a record by id" do
      stored = store.add(rec("temp", embedding: [1.0, 0.0, 0.0]))
      store.delete(id: stored.id)
      expect(store.all(scope: "u:1")).to be_empty
    end
  end
end
