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
    expect(converted.embedding).to equal(record.embedding)
    expect(converted.metadata.dig("host", "kept")).to be(true)
    expect(Engram::EmbeddingMetadata.extract(converted.metadata)).to eq(embedding)
    expect(Engram::Provenance.extract(converted.metadata)).to eq(provenance)
    expect(record.metadata).to eq(metadata)
  end

  it "requires Record and Provenance values" do
    expect { described_class.new(record: Object.new, provenance: provenance) }
      .to raise_error(ArgumentError, /record/)
    expect { described_class.new(record: Engram::Record.new(content: "Tea", scope: "user:1"), provenance: Object.new) }
      .to raise_error(ArgumentError, /provenance/)
  end
end
