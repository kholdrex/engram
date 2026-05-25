# frozen_string_literal: true

# End-to-end Rails integration. Boots a minimal Rails app (spec/support/rails_app.rb) and
# exercises the glue layer against a real Postgres + pgvector database:
#   * has_memory on an ActiveRecord model
#   * recall through the PgvectorStore
#   * background observation via ObserveJob (ActiveJob, inline adapter)
#   * Rails.cache-backed idempotency (CacheProcessedTurns)
#
# Tagged :integration; needs the integration bundle group (rails, pg, neighbor) and a DB:
#   DATABASE_URL=postgres://postgres:postgres@localhost:5432/engram_test \
#     bundle exec rspec --tag integration
#
# The embedding column is vector(3) to stay compatible with the pgvector store spec, which
# shares the engram_memories table.

deps_available =
  begin
    require "rails"
    require "active_record/railtie"
    require "active_job/railtie"
    require "pg"
    require "neighbor"
    true
  rescue LoadError
    false
  end

if deps_available
  require_relative "../support/rails_app"

  RSpec.describe "Rails integration (E2E)", :integration do
    before(:all) do
      conn = ActiveRecord::Base.connection
      conn.enable_extension("vector") unless conn.extension_enabled?("vector")

      conn.create_table(:users, force: true) do |t|
        t.string :name
        t.timestamps
      end

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

      Engram::MemoryRecord.reset_column_information
      User.reset_column_information
    end

    after(:all) do
      conn = ActiveRecord::Base.connection
      conn.drop_table(:engram_memories, if_exists: true)
      conn.drop_table(:users, if_exists: true)
    end

    before do
      Engram::MemoryRecord.delete_all
      User.delete_all
      Rails.cache.clear
      Engram.configure do |c|
        c.store = Engram::Adapters::PgvectorStore.new
        c.embedder = Engram::Adapters::NullEmbedder.new(dimensions: 3)
      end
    end

    it "wires has_memory onto models and round-trips a fact through pgvector" do
      user = User.create!(name: "Ada")

      expect(user.memory.scope).to eq("user:#{user.id}")

      user.memory.add("prefers concise answers")
      results = user.memory.recall("prefers concise answers", limit: 1)

      expect(results.first.content).to eq("prefers concise answers")
      expect(Engram::MemoryRecord.where(scope: "user:#{user.id}").count).to eq(1)
    end

    it "isolates memories between owners" do
      ada = User.create!(name: "Ada")
      bob = User.create!(name: "Bob")

      ada.memory.add("Ada's note")

      expect(ada.memory.all.map(&:content)).to eq(["Ada's note"])
      expect(bob.memory.all).to be_empty
    end

    it "observes a turn off the request path via ObserveJob" do
      Engram.config.completion = Engram::Adapters::FakeCompletion.new(responses: [
        {"facts" => [{"content" => "User likes tea", "confidence" => 0.9}]}
      ])
      user = User.create!(name: "Cara")

      user.memory.observe_later(["I like tea"])

      expect(user.memory.all.map(&:content)).to eq(["User likes tea"])
    end

    it "stays idempotent across job runs via Rails.cache-backed ProcessedTurns" do
      Engram.config.processed_turns = Engram::Rails::CacheProcessedTurns.new
      completion = Engram::Adapters::FakeCompletion.new(responses: [
        {"facts" => [{"content" => "User likes tea", "confidence" => 0.9}]}
      ])
      Engram.config.completion = completion
      user = User.create!(name: "Dev")

      user.memory.observe_later(["I like tea"])
      user.memory.observe_later(["I like tea"])

      expect(user.memory.all.map(&:content)).to eq(["User likes tea"])
      expect(completion.calls.size).to eq(1)
    end
  end
end
