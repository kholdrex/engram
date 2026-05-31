# frozen_string_literal: true

# Verifies the Rails install generator produces the files the gem promises (migration,
# initializer, model) and honours the --dimensions option. Tagged :integration because it
# needs railties (the integration bundle group). No database required.

deps_available =
  begin
    require "rails/generators"
    require "rails/generators/active_record"
    true
  rescue LoadError
    false
  end

if deps_available
  require "generators/engram/install_generator"
  require "fileutils"

  RSpec.describe Engram::Generators::InstallGenerator, :integration do
    let(:destination) { File.expand_path("../../tmp/generator_spec", __dir__) }
    let(:generator_opts) { {} }

    before do
      FileUtils.rm_rf(destination)
      FileUtils.mkdir_p(destination)
    end

    after { FileUtils.rm_rf(destination) }

    def migration_path
      Dir[File.join(destination, "db/migrate/*_create_engram_memories.rb")].first
    end

    def migration_contents
      File.read(migration_path)
    end

    def invoke_generator
      described_class.new([], generator_opts, destination_root: destination).invoke_all
    end

    context "with valid options" do
      before { invoke_generator }

      it "creates the migration for the engram_memories table" do
        expect(migration_path).not_to be_nil, "expected migration file to be generated but none was found"
        expect(migration_contents).to include("create_table :engram_memories")
        expect(migration_contents).to include("t.vector :embedding, limit: 1536")
        expect(migration_contents).to include('t.string :kind, null: false, default: "fact"')
      end

      it "creates the initializer pointing at the pgvector store" do
        initializer = File.read(File.join(destination, "config/initializers/engram.rb"))
        expect(initializer).to include("Engram::Adapters::PgvectorStore.new")
      end

      it "creates the ActiveRecord model with neighbor wired in" do
        model = File.read(File.join(destination, "app/models/engram/memory_record.rb"))
        expect(model).to include("has_neighbors :embedding")
      end

      it "documents production vector index choices in the generated migration" do
        expect(migration_contents).to include("choose one approximate vector index")
        expect(migration_contents).to include("using: :hnsw, opclass: :vector_cosine_ops")
        expect(migration_contents).to include("using: :ivfflat, opclass: :vector_cosine_ops")
        expect(migration_contents).to include("vector_cosine_ops")
      end
    end

    context "with a custom --dimensions option" do
      let(:generator_opts) { {dimensions: 768} }

      before { invoke_generator }

      it "uses the requested embedding size in the migration" do
        expect(migration_path).not_to be_nil, "expected migration file to be generated but none was found"
        expect(migration_contents).to include("t.vector :embedding, limit: 768")
      end
    end

    context "with an invalid --dimensions option" do
      [0, -1, 1.5].each do |invalid_dimensions|
        context "with dimensions=#{invalid_dimensions}" do
          let(:generator_opts) { {dimensions: invalid_dimensions} }

          it "raises a clear configuration error" do
            expect { invoke_generator }
              .to raise_error(ArgumentError,
                "dimensions must be a positive integer that matches your embedding model")
          end
        end
      end
    end
  end
end
