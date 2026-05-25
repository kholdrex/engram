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

    def rec(content, embedding:, scope: "u:1")
      Engram::Record.new(content: content, scope: scope, embedding: embedding)
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
