# frozen_string_literal: true

RSpec.describe Engram::UseCases::RebuildEmbeddings do
  subject(:rebuild) { described_class.new(store: store, embedder: embedder) }

  let(:store) { Engram::Adapters::InMemoryStore.new }
  let(:embedder) { Engram::Adapters::NullEmbedder.new }

  def add_record(content:, scope: "u:1", metadata: nil)
    record = Engram::Record.new(
      content: content,
      scope: scope,
      embedding: embedder.embed(content),
      metadata: metadata || {}
    )
    record = Engram::EmbeddingMetadata.attach(record, embedder: embedder) if metadata.nil?
    store.add(record)
  end

  it "updates stale records by default" do
    stale = Engram::Record.new(content: "hello", scope: "u:1", embedding: embedder.embed("hello"))
    fresh = Engram::Record.new(content: "world", scope: "u:1", embedding: embedder.embed("world"), metadata: {})
    fresh = Engram::EmbeddingMetadata.attach(fresh, embedder: embedder)
    store.add(stale)
    store.add(fresh)

    result = rebuild.call(scope: "u:1")

    expect(result[:processed]).to eq(2)
    expect(result[:updated]).to eq(1)
    expect(result[:skipped]).to eq(1)
    expect(result[:failed]).to eq(0)

    rebuilt = store.all(scope: "u:1").find { |record| record.content == "hello" }
    expect(rebuilt.metadata).to include("_engram" => include("embedding" => include("fingerprint" => be_a(String))))
  end

  it "honors stale_only: false and rebuilds all records" do
    add_record(content: "first")
    add_record(content: "second")

    result = rebuild.call(scope: "u:1", stale_only: false, batch_size: 1)

    expect(result[:updated]).to eq(2)
    expect(result[:skipped]).to eq(0)
    expect(result[:processed]).to eq(2)
  end

  it "walks multiple batches without skipping records" do
    add_record(content: "first")
    add_record(content: "second")
    add_record(content: "third")

    result = rebuild.call(scope: "u:1", stale_only: false, batch_size: 2)

    expect(result[:processed]).to eq(3)
    expect(result[:updated]).to eq(3)
    expect(result[:skipped]).to eq(0)
  end

  it "does not refetch forever when a batched page ends with a nil-id record" do
    malformed_record = Engram::Record.new(
      id: nil,
      content: "legacy without id",
      scope: "u:1",
      embedding: embedder.embed("legacy without id"),
      metadata: {}
    )
    valid_record = Engram::Record.new(
      id: 1,
      content: "first",
      scope: "u:1",
      embedding: embedder.embed("first"),
      metadata: {}
    )

    store_class = Class.new do
      include Engram::Ports::MemoryStore

      attr_reader :all_calls

      def initialize(records)
        @records = records
        @all_calls = 0
      end

      def add(record) = raise NotImplementedError
      def search(...) = raise NotImplementedError
      def delete(id:) = raise NotImplementedError
      def touch(id:, at: Time.now) = raise NotImplementedError

      def all(scope:, limit: nil, offset: 0, after_id: nil)
        @all_calls += 1
        records = @records.select { |record| record.scope == scope }
        records = records.drop_while { |record| !after_id.nil? && record.id && record.id <= after_id }
        records = records.drop(offset) if offset.positive?
        records = records.take(limit) if limit
        records
      end

      def update(id:, record:)
        index = @records.index { |existing| existing.id == id }
        @records[index] = record
        record
      end
    end

    paged_store = store_class.new([valid_record, malformed_record])

    result = described_class.new(store: paged_store, embedder: embedder).call(
      scope: "u:1",
      stale_only: false,
      batch_size: 2
    )

    expect(result[:processed]).to eq(2)
    expect(result[:updated]).to eq(1)
    expect(result[:skipped]).to eq(1)
    expect(paged_store.all_calls).to eq(2)
  end

  it "falls back to legacy stores that only support all(scope:)" do
    legacy_store_class = Class.new do
      include Engram::Ports::MemoryStore

      attr_reader :records

      def initialize(records)
        @records = records
      end

      def add(record)
        @records << record
        record
      end

      def search(...) = raise NotImplementedError

      def all(scope:)
        @records.select { |record| record.scope == scope }
      end

      def update(id:, record:)
        index = @records.index { |existing| existing.id == id }
        @records[index] = record
        record
      end

      def delete(id:) = raise NotImplementedError

      def touch(id:, at: Time.now) = raise NotImplementedError
    end

    legacy_store = legacy_store_class.new([
      add_record(content: "first"),
      add_record(content: "second"),
      add_record(content: "third")
    ])

    result = described_class.new(store: legacy_store, embedder: embedder).call(
      scope: "u:1",
      stale_only: false,
      batch_size: 2
    )

    expect(result[:processed]).to eq(3)
    expect(result[:updated]).to eq(3)
    expect(result[:skipped]).to eq(0)
    expect(legacy_store.records.map(&:embedding)).to all(satisfy { |embedding| !embedding.nil? && !embedding.empty? })
  end

  it "falls back when a legacy store accepts extra keywords but ignores batching" do
    permissive_store_class = Class.new do
      include Engram::Ports::MemoryStore

      attr_reader :records

      def initialize(records)
        @records = records
      end

      def add(record)
        @records << record
        record
      end

      def search(...) = raise NotImplementedError

      def all(scope:, **_kwargs)
        @records.select { |record| record.scope == scope }
      end

      def update(id:, record:)
        index = @records.index { |existing| existing.id == id }
        @records[index] = record
        record
      end

      def delete(id:) = raise NotImplementedError

      def touch(id:, at: Time.now) = raise NotImplementedError
    end

    permissive_store = permissive_store_class.new([
      add_record(content: "first"),
      add_record(content: "second"),
      add_record(content: "third")
    ])

    result = described_class.new(store: permissive_store, embedder: embedder).call(
      scope: "u:1",
      stale_only: false,
      batch_size: 2
    )

    expect(result[:processed]).to eq(3)
    expect(result[:updated]).to eq(3)
    expect(result[:skipped]).to eq(0)
    expect(permissive_store.records.map(&:embedding)).to all(satisfy { |embedding| !embedding.nil? && !embedding.empty? })
  end

  it "falls back when a batched store ignores after_id progression" do
    paged_store_class = Class.new do
      include Engram::Ports::MemoryStore

      attr_reader :records, :all_calls

      def initialize(records)
        @records = records
        @all_calls = 0
      end

      def add(record)
        @records << record
        record
      end

      def search(...) = raise NotImplementedError

      def all(scope:, limit: nil, after_id: nil)
        @all_calls += 1
        @records.select { |record| record.scope == scope }.take(limit || @records.length)
      end

      def update(id:, record:)
        index = @records.index { |existing| existing.id == id }
        @records[index] = record
        record
      end

      def delete(id:) = raise NotImplementedError

      def touch(id:, at: Time.now) = raise NotImplementedError
    end

    paged_store = paged_store_class.new([
      add_record(content: "first"),
      add_record(content: "second"),
      add_record(content: "third")
    ])

    result = described_class.new(store: paged_store, embedder: embedder).call(
      scope: "u:1",
      stale_only: false,
      batch_size: 2
    )

    expect(result[:processed]).to eq(3)
    expect(result[:updated]).to eq(3)
    expect(result[:skipped]).to eq(0)
    expect(paged_store.records.map(&:embedding)).to all(satisfy { |embedding| !embedding.nil? && !embedding.empty? })
    expect(paged_store.all_calls).to eq(3)
  end

  it "falls back to legacy slicing when a batched page ends with a nil-id record" do
    malformed_record = Engram::Record.new(
      id: nil,
      content: "legacy without id",
      scope: "u:1",
      embedding: embedder.embed("legacy without id"),
      metadata: {}
    )

    paged_store_class = Class.new do
      include Engram::Ports::MemoryStore

      def initialize(records)
        @records = records
      end

      def add(record) = raise NotImplementedError
      def search(...) = raise NotImplementedError
      def delete(id:) = raise NotImplementedError
      def touch(id:, at: Time.now) = raise NotImplementedError

      def all(scope:, limit: nil, offset: 0, after_id: nil)
        records = @records.select { |record| record.scope == scope }
        records = records.drop_while { |record| !after_id.nil? && record.id && record.id <= after_id }
        records = records.drop(offset) if offset.positive?
        records = records.take(limit) if limit
        records
      end

      def update(id:, record:)
        index = @records.index { |existing| existing.id == id }
        @records[index] = record
        record
      end
    end

    paged_store = paged_store_class.new([
      Engram::Record.new(id: 1, content: "first", scope: "u:1", embedding: embedder.embed("first"), metadata: {}),
      malformed_record,
      Engram::Record.new(id: 2, content: "second", scope: "u:1", embedding: embedder.embed("second"), metadata: {})
    ])

    result = described_class.new(store: paged_store, embedder: embedder).call(
      scope: "u:1",
      stale_only: false,
      batch_size: 2
    )

    expect(result[:processed]).to eq(3)
    expect(result[:updated]).to eq(2)
    expect(result[:skipped]).to eq(1)
  end

  it "falls back to legacy slicing when a batched page contains only nil ids before valid rows" do
    paged_store_class = Class.new do
      include Engram::Ports::MemoryStore

      def initialize(records)
        @records = records
      end

      def add(record) = raise NotImplementedError
      def search(...) = raise NotImplementedError
      def delete(id:) = raise NotImplementedError
      def touch(id:, at: Time.now) = raise NotImplementedError

      def all(scope:, limit: nil, offset: 0, after_id: nil)
        records = @records.select { |record| record.scope == scope }
        records = records.drop_while { |record| !after_id.nil? && record.id && record.id <= after_id }
        records = records.drop(offset) if offset.positive?
        records = records.take(limit) if limit
        records
      end

      def update(id:, record:)
        index = @records.index { |existing| existing.id == id }
        @records[index] = record
        record
      end
    end

    paged_store = paged_store_class.new([
      Engram::Record.new(id: nil, content: "legacy without id", scope: "u:1", embedding: embedder.embed("legacy without id"), metadata: {}),
      Engram::Record.new(id: 1, content: "first", scope: "u:1", embedding: embedder.embed("first"), metadata: {}),
      Engram::Record.new(id: 2, content: "second", scope: "u:1", embedding: embedder.embed("second"), metadata: {})
    ])

    result = described_class.new(store: paged_store, embedder: embedder).call(
      scope: "u:1",
      stale_only: false,
      batch_size: 1
    )

    expect(result[:processed]).to eq(3)
    expect(result[:updated]).to eq(2)
    expect(result[:skipped]).to eq(1)
  end

  it "falls back when later batched pages repeat a leading nil-id row while valid ids advance" do
    paged_store_class = Class.new do
      include Engram::Ports::MemoryStore

      def initialize(records)
        @records = records
      end

      def add(record) = raise NotImplementedError
      def search(...) = raise NotImplementedError
      def delete(id:) = raise NotImplementedError
      def touch(id:, at: Time.now) = raise NotImplementedError

      def all(scope:, limit: nil, after_id: nil)
        records = @records.select { |record| record.scope == scope }
        return records.take(limit || records.length) if after_id.nil?

        tail = records.select { |record| record.id && record.id > after_id }
        ([records.first] + tail).take(limit || records.length)
      end

      def update(id:, record:)
        index = @records.index { |existing| existing.id == id }
        @records[index] = record
        record
      end
    end

    paged_store = paged_store_class.new([
      Engram::Record.new(id: nil, content: "legacy without id", scope: "u:1", embedding: embedder.embed("legacy without id"), metadata: {}),
      Engram::Record.new(id: 1, content: "first", scope: "u:1", embedding: embedder.embed("first"), metadata: {}),
      Engram::Record.new(id: 2, content: "second", scope: "u:1", embedding: embedder.embed("second"), metadata: {}),
      Engram::Record.new(id: 3, content: "third", scope: "u:1", embedding: embedder.embed("third"), metadata: {})
    ])

    result = described_class.new(store: paged_store, embedder: embedder).call(
      scope: "u:1",
      stale_only: false,
      batch_size: 2
    )

    expect(result[:processed]).to eq(4)
    expect(result[:updated]).to eq(3)
    expect(result[:skipped]).to eq(1)
  end

  it "falls back when a later batched page repeats the same valid id" do
    paged_store_class = Class.new do
      include Engram::Ports::MemoryStore

      def initialize(records)
        @records = records
      end

      def add(record) = raise NotImplementedError
      def search(...) = raise NotImplementedError
      def delete(id:) = raise NotImplementedError
      def touch(id:, at: Time.now) = raise NotImplementedError

      def all(scope:, limit: nil, after_id: nil)
        records = @records.select { |record| record.scope == scope }
        return records.take(limit || records.length) if after_id.nil?

        duplicated_page = [records[2], records[2], records[3]]
        duplicated_page.take(limit || duplicated_page.length)
      end

      def update(id:, record:)
        index = @records.index { |existing| existing.id == id }
        @records[index] = record
        record
      end
    end

    paged_store = paged_store_class.new([
      Engram::Record.new(id: 1, content: "first", scope: "u:1", embedding: embedder.embed("first"), metadata: {}),
      Engram::Record.new(id: 2, content: "second", scope: "u:1", embedding: embedder.embed("second"), metadata: {}),
      Engram::Record.new(id: 3, content: "third", scope: "u:1", embedding: embedder.embed("third"), metadata: {}),
      Engram::Record.new(id: 4, content: "fourth", scope: "u:1", embedding: embedder.embed("fourth"), metadata: {})
    ])

    result = described_class.new(store: paged_store, embedder: embedder).call(
      scope: "u:1",
      stale_only: false,
      batch_size: 2
    )

    expect(result[:processed]).to eq(4)
    expect(result[:updated]).to eq(4)
    expect(result[:skipped]).to eq(0)
    expect(paged_store.all(scope: "u:1").map(&:content)).to eq(%w[first second third fourth])
  end

  it "reconciles adversarial pages by ID against a stable snapshot" do
    record = ->(id) do
      Engram::Record.new(
        id: id,
        content: id ? "record-#{id}" : "record-without-id",
        scope: "u:1",
        embedding: embedder.embed(id.to_s),
        metadata: {}
      )
    end

    adversarial_store_class = Class.new do
      include Engram::Ports::MemoryStore

      attr_reader :updated_ids, :all_calls

      def initialize(snapshot, pages)
        @snapshot = snapshot
        @pages = pages
        @updated_ids = []
        @all_calls = 0
      end

      def all(scope:, limit: nil, after_id: nil)
        @all_calls += 1
        return @snapshot.select { |item| item.scope == scope } unless limit

        @pages.shift || []
      end

      def update(id:, record:)
        @updated_ids << id
        index = @snapshot.index { |item| item.id == id }
        @snapshot[index] = record
      end

      def add(record) = raise NotImplementedError
      def search(...) = raise NotImplementedError
      def delete(id:) = raise NotImplementedError
      def touch(id:, at: Time.now) = raise NotImplementedError
    end

    scenarios = [
      [[2, 1], [2, 3]],
      [[1, 3], []],
      [[2, nil], [2, 1], [1, 3], [3, nil], []]
    ]

    scenarios.each do |page_ids|
      snapshot = [1, 2, 3, 4].map { |id| record.call(id) }
      nil_record = record.call(nil)
      pages = page_ids.map do |ids|
        ids.map { |id| id.nil? ? nil_record : snapshot.fetch(id - 1) }
      end
      adversarial_store = adversarial_store_class.new(snapshot, pages)

      result = described_class.new(store: adversarial_store, embedder: embedder).call(
        scope: "u:1", stale_only: false, batch_size: 2
      )

      expect(adversarial_store.updated_ids).to contain_exactly(1, 2, 3, 4)
      expect(adversarial_store.updated_ids.uniq).to eq(adversarial_store.updated_ids)
      expect(result[:processed]).to eq(4 + (page_ids.flatten.include?(nil) ? 1 : 0))
      expect(adversarial_store.all_calls).to be <= 6
    end
  end

  it "only processes records in the requested scope" do
    add_record(content: "in_scope", metadata: {})
    add_record(content: "other_scope", scope: "u:2", metadata: {})

    result = rebuild.call(scope: "u:1")

    expect(result[:processed]).to eq(1)
    expect(result[:updated]).to eq(1)
  end

  it "rebuilds records with mismatched embedding metadata" do
    incompatible = Engram::Record.new(
      content: "gamma",
      scope: "u:1",
      embedding: embedder.embed("gamma"),
      metadata: {
        "_engram" => {
          "embedding" => {
            "adapter" => "Engram::Adapters::NullEmbedder",
            "provider" => "null",
            "model" => "legacy",
            "dimensions" => embedder.dimensions,
            "fingerprint" => "different"
          }
        }
      }
    )
    store.add(incompatible)

    result = rebuild.call(scope: "u:1")

    expect(result[:updated]).to eq(1)
    expect(store.all(scope: "u:1").first.metadata.dig("_engram", "embedding", "fingerprint")).to eq(
      Engram::EmbeddingMetadata.for_embedder(embedder, embedding: embedder.embed("gamma"))["fingerprint"]
    )
  end

  it "raises on non-positive batch size" do
    expect do
      rebuild.call(scope: "u:1", batch_size: 0)
    end.to raise_error(ArgumentError, "batch_size must be greater than 0")
  end

  it "tracks failed rows when embedding fails" do
    stale_record = Engram::Record.new(
      content: "broken",
      scope: "u:1",
      embedding: embedder.embed("broken"),
      metadata: {}
    )
    store.add(stale_record)

    allow(embedder).to receive(:embed).and_raise(StandardError, "transform failed")

    result = rebuild.call(scope: "u:1")

    expect(result[:processed]).to eq(1)
    expect(result[:updated]).to eq(0)
    expect(result[:failed]).to eq(1)
    expect(result[:failed_ids]).to eq([1])
    expect(result[:failed_errors]).to include(
      1 => {
        class: "StandardError",
        message: "transform failed"
      }
    )
    expect(result[:skipped]).to eq(0)
  end
end
