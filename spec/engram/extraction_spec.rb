# frozen_string_literal: true

RSpec.describe Engram::Extraction do
  let(:provenance) do
    Engram::Provenance.new(
      sources: [Engram::Provenance::Source.new(
        source_id: "message:1", source_type: "message", message_index: 0, role: "user",
        spans: [Engram::Provenance::Span.new(start_offset: 0, end_offset: 4)], alignment: :exact
      )],
      extractor: Engram::Provenance::Extractor.new(name: "host", model: "model-1"),
      confidence: 0.9
    )
  end

  it "is an immutable provenance-bearing extractor result" do
    record = Engram::Record.new(content: "Tea", scope: "user:1")
    extraction = described_class.new(record: record, provenance: provenance)

    expect(extraction.record).to equal(record)
    expect(extraction.provenance).to equal(provenance)
    expect(extraction).to be_frozen
  end

  it "creates a record with provenance without mutating the input or losing metadata" do
    embedding = Engram::EmbeddingMetadata.build(adapter: "test", dimensions: 2)
    metadata = Engram::EmbeddingMetadata.merge({"host" => {"kept" => true}}, embedding)
    record = Engram::Record.new(content: "Tea", scope: "user:1", embedding: [0.1, 0.2], metadata: metadata)

    converted = described_class.new(record: record, provenance: provenance).to_record

    expect(converted).not_to equal(record)
    expect(converted.embedding).to eq(record.embedding)
    expect(converted.embedding).not_to equal(record.embedding)
    expect(converted.metadata.dig("host", "kept")).to be(true)
    expect(Engram::EmbeddingMetadata.extract(converted.metadata)).to eq(embedding)
    expect(Engram::Provenance.extract(converted.metadata)).to eq(provenance)
    expect(record.metadata).to eq(metadata)
  end

  it "attaches ungrounded provenance through behavior-free metadata without laundering it" do
    calls = []
    hostile_hash = Class.new(Hash) do
      define_method(:dup) do
        calls << :dup
        self
      end
      define_method(:delete) do |key|
        calls << :delete
        super(key)
      end
      define_method(:reject) do |&block|
        calls << :reject
        super(&block)
      end
      define_method(:merge) do |*arguments|
        calls << :merge
        super(*arguments).except("_engram")
      end
    end
    reserved = hostile_hash.new
    reserved["host"] = {"kept" => true}
    metadata = hostile_hash.new
    metadata["caller"] = {"kept" => true}
    metadata["_engram"] = reserved
    record = Engram::Record.new(content: "Tea", scope: "user:1", embedding: [0.0], metadata: metadata)
    ungrounded = Engram::Provenance.new(
      sources: [Engram::Provenance::Source.new(
        source_id: "message:1", source_type: "message", message_index: 0, role: "user",
        spans: [Engram::Provenance::Span.new(start_offset: 0, end_offset: 4)], alignment: :ungrounded
      )],
      extractor: provenance.extractor,
      confidence: provenance.confidence
    )
    original_entries = Hash.instance_method(:transform_values).bind_call(metadata) { |value| value }
    store = Engram::Adapters::InMemoryStore.new

    converted = described_class.new(record: record, provenance: ungrounded).to_record
    persisted = Engram::Persistence.new(store: store, embedder: Engram::Adapters::NullEmbedder.new).add(converted)

    expect(converted.metadata).to be_instance_of(Hash)
    expect(Engram::Provenance.extract(converted.metadata)).to eq(ungrounded)
    expect(persisted).to be_nil
    expect(store.all(scope: "user:1")).to be_empty
    expect(calls).to be_empty
    expect(Hash.instance_method(:each_pair).bind_call(metadata).to_a).to eq(original_entries.to_a)
    expect(metadata.fetch("_engram")).to equal(reserved)
  end

  it "converts Record subclasses without invoking overridden type checks or readers" do
    record_class = Class.new(Engram::Record) do
      def is_a?(_class)
        raise "subclass type check must not be invoked"
      end

      def metadata
        raise "subclass reader must not be invoked"
      end
    end
    metadata = {"host" => true}
    record = record_class.new(content: "Tea", scope: "user:1", metadata: metadata)

    converted = described_class.new(record: record, provenance: provenance).to_record

    expect(converted).to be_instance_of(Engram::Record)
    expect(converted.content).to eq("Tea")
    expect(converted.metadata).to include("host" => true)
    expect(Engram::Provenance.extract(converted.metadata)).to eq(provenance)
    expect(metadata).to eq("host" => true)
  end

  it "rejects singleton Record behavior before invoking metadata or with" do
    invoked = []

    %i[metadata with].each do |method_name|
      record = Engram::Record.new(content: "Tea", scope: "user:1")
      record.define_singleton_method(method_name) do |**|
        invoked << method_name
        raise "singleton #{method_name} must not be invoked"
      end

      extraction = described_class.new(record: record, provenance: provenance)

      expect { extraction.to_record }
        .to raise_error(Engram::Internal::CandidateIntegrity::InvalidStateError, /plain Engram::Record/)
    end

    expect(invoked).to be_empty
  end

  it "requires Record and Provenance values" do
    expect { described_class.new(record: Object.new, provenance: provenance) }
      .to raise_error(ArgumentError, /record/)
    expect { described_class.new(record: Engram::Record.new(content: "Tea", scope: "user:1"), provenance: Object.new) }
      .to raise_error(ArgumentError, /provenance/)
  end
end
