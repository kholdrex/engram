# frozen_string_literal: true

require "tmpdir"
require "erb"

deps_available =
  begin
    require "active_record"
    require "pg"
    require "neighbor"
    require "generators/engram/expiry_generator"
    true
  rescue LoadError
    false
  end

if deps_available
  RSpec.describe "Expiry upgrade from 0.7.0", :integration do
    let(:model) do
      Class.new(ActiveRecord::Base) do
        self.table_name = "engram_memories"
        has_neighbors :embedding
      end
    end
    let(:store) { Engram::Adapters::PgvectorStore.new(model: model) }
    let(:memory) do
      Engram::Memory.new(scope: "user:1", store: store,
        embedder: Engram::Adapters::NullEmbedder.new(dimensions: 3))
    end

    around do |example|
      ActiveRecord::Base.establish_connection(
        ENV.fetch("DATABASE_URL", "postgres://postgres:postgres@localhost:5432/engram_test")
      )
      Dir.mktmpdir("engram-expiry-upgrade") do |destination|
        template_path = File.expand_path("../fixtures/migrations/create_engram_memories_0_7_0.rb.tt", __dir__)
        template = File.read(template_path)
        schema = ERB.new(template).result_with_hash(migration_version: "7.0", dimensions: 3)
        @legacy_migration = Module.new.module_eval("#{schema}\nCreateEngramMemories", __FILE__, __LINE__).new
        ActiveRecord::Migration.suppress_messages { @legacy_migration.migrate(:up) }

        Engram::Generators::ExpiryGenerator.new([], {}, destination_root: destination).invoke_all
        files = Dir[File.join(destination, "db/migrate/*_add_expiry_to_engram_memories.rb")]
        expect(files.length).to eq(1)
        @upgrade = Module.new.module_eval("#{File.read(files.first)}\nAddExpiryToEngramMemories", __FILE__, __LINE__).new
        example.run
      ensure
        ActiveRecord::Base.connection.drop_table(:engram_memories, if_exists: true)
      end
    end

    def migrate(direction)
      ActiveRecord::Migration.suppress_messages { @upgrade.migrate(direction) }
      model.reset_column_information
    end

    it "preserves existing rows and supports expiring writes after migration" do
      legacy = memory.add("permanent preference", metadata: {"host" => "kept"})
      before = model.find(legacy.id).attributes
      expect(memory.recall("permanent preference").map(&:id)).to eq([legacy.id])
      expect(memory.forget_expired).to eq(matched: 0, deleted: 0, dry_run: false)
      expect { memory.add("trial", expires_at: Time.now + 60) }
        .to raise_error(Engram::Error, /expires_at datetime column/)

      migrate(:up)

      expect(model.find(legacy.id).attributes.except("expires_at")).to eq(before)
      expect(model.find(legacy.id).expires_at).to be_nil
      now = Time.utc(2026, 9, 15, 12)
      allow(Time).to receive(:now).and_return(now)
      trial = memory.add("trial", expires_at: now + 1)
      expect(memory.recall("trial", limit: 1).map(&:id)).to eq([trial.id])
      allow(Time).to receive(:now).and_return(now + 1)
      expect(memory.recall("trial", limit: 1).map(&:id)).to eq([legacy.id])
      expect(model.count).to eq(2)
      expect(memory.forget_expired).to eq(matched: 1, deleted: 1, dry_run: false)
      expect(model.pluck(:id)).to eq([legacy.id])

      index = model.connection.indexes(:engram_memories)
        .find { |value| value.name == "index_engram_memories_on_scope_and_expiry" }
      expect(index.columns).to eq(%w[scope expires_at])
      expect(index.where).to include("expires_at IS NOT NULL")
      expect(index.valid?).to be(true)
    end

    it "rolls back the column and index without removing existing memories" do
      legacy = memory.add("permanent preference")
      migrate(:up)
      migrate(:down)

      expect(model.column_names).not_to include("expires_at")
      expect(model.connection.indexes(:engram_memories).map(&:name))
        .not_to include("index_engram_memories_on_scope_and_expiry")
      expect(memory.recall("permanent preference").map(&:id)).to eq([legacy.id])
      expect(memory.add("another preference").expires_at).to be_nil
    end
  end
end
