# frozen_string_literal: true

RSpec.describe Engram::Provenance do
  def provenance
    described_class.new(
      sources: [
        described_class::Source.new(
          source_id: "conversation:42",
          source_type: "conversation",
          message_index: 3,
          role: "user",
          spans: [described_class::Span.new(start_offset: 6, end_offset: 15)],
          alignment: :exact
        )
      ],
      extractor: described_class::Extractor.new(
        name: "host-extractor", provider: "example", model: "model-1"
      ),
      confidence: 0.92
    )
  end

  it "provides immutable, provider-neutral value objects with explicit offset semantics" do
    value = provenance
    span = value.sources.first.spans.first

    expect(span.offset_unit).to eq("unicode_codepoint")
    expect(span.end_exclusive?).to be(true)
    expect(value).to be_frozen
    expect(value.sources).to be_frozen
    expect(value.sources.first).to be_frozen
    expect(span).to be_frozen
    expect(value.extractor).to be_frozen
  end

  it "does not freeze mutable strings owned by its caller" do
    source_id = +"message:1"
    extractor_name = +"extractor"

    described_class::Source.new(
      source_id: source_id, source_type: "message", message_index: 0, role: "user",
      spans: [described_class::Span.new(start_offset: 0, end_offset: 1)], alignment: :inferred
    )
    described_class::Extractor.new(name: extractor_name, model: "model-1")

    expect(source_id).not_to be_frozen
    expect(extractor_name).not_to be_frozen
  end

  it "rejects unknown alignment values" do
    expect do
      described_class::Source.new(
        source_id: "message:1", source_type: "message", message_index: 0, role: "user",
        spans: [described_class::Span.new(start_offset: 0, end_offset: 1)], alignment: :approximate
      )
    end.to raise_error(ArgumentError, /alignment/)
  end

  it "rejects malformed collections and non-real confidence values consistently" do
    expect do
      described_class::Source.new(
        source_id: "message:1", source_type: "message", message_index: 0, role: "user",
        spans: nil, alignment: :exact
      )
    end.to raise_error(ArgumentError, "spans must be an array")

    expect do
      described_class.new(
        sources: nil, extractor: described_class::Extractor.new(name: "test", model: "model-1"), confidence: 1.0
      )
    end.to raise_error(ArgumentError, "sources must be an array")

    expect do
      described_class.new(
        sources: [provenance.sources.first],
        extractor: described_class::Extractor.new(name: "test", model: "model-1"), confidence: Complex(0, 1)
      )
    end.to raise_error(ArgumentError, "confidence must be between 0 and 1")
  end

  it "requires complete source location and extractor identity fields" do
    expect do
      described_class::Source.new(
        source_id: "message:1", source_type: "message", spans: [], alignment: :exact
      )
    end.to raise_error(ArgumentError, "message_index must be a non-negative integer")

    expect do
      described_class::Source.new(
        source_id: "message:1", source_type: "message", message_index: 0, role: "user",
        spans: [], alignment: :exact
      )
    end.to raise_error(ArgumentError, "spans must contain at least one span")

    expect do
      described_class::Extractor.new(name: "test")
    end.to raise_error(ArgumentError, "extractor model is required")

    expect do
      described_class.new(
        sources: [provenance.sources.first],
        extractor: described_class::Extractor.new(name: "test", model: "model-1")
      )
    end.to raise_error(ArgumentError, "confidence must be between 0 and 1")
  end

  it "rejects empty and reversed character spans" do
    expect do
      described_class::Span.new(start_offset: 2, end_offset: 2)
    end.to raise_error(ArgumentError, /end_offset > start_offset/)

    expect do
      described_class::Span.new(start_offset: 3, end_offset: 2)
    end.to raise_error(ArgumentError, /end_offset > start_offset/)
  end

  it "round-trips through the versioned reserved metadata schema" do
    metadata = described_class.attach({"tenant_field" => "kept"}, provenance)

    expect(metadata).to include("tenant_field" => "kept")
    expect(metadata.dig("_engram", "provenance", "version")).to eq(1)
    expect(metadata.dig("_engram", "provenance", "sources", 0, "spans", 0)).to eq(
      "start_offset" => 6,
      "end_offset" => 15,
      "offset_unit" => "unicode_codepoint"
    )
    expect(described_class.extract(metadata)).to eq(provenance)
  end

  it "coexists with embedding metadata under the reserved namespace" do
    embedding = Engram::EmbeddingMetadata.build(adapter: "test", dimensions: 3)
    metadata = Engram::EmbeddingMetadata.merge({}, embedding)
    metadata = described_class.attach(metadata, provenance)
    metadata = Engram::EmbeddingMetadata.merge(metadata, embedding)

    expect(Engram::EmbeddingMetadata.extract(metadata)).to eq(embedding)
    expect(described_class.extract(metadata)).to eq(provenance)
  end

  it "leaves legacy records and plain Record custom extractor results readable" do
    legacy = Engram::Record.new(
      content: "User likes tea", scope: "user:1", metadata: {"custom" => true}
    )
    legacy_reserved = Engram::Record.new(
      content: "Legacy", scope: "user:1", metadata: {"_engram" => "legacy user data"}
    )

    expect(described_class.extract(legacy.metadata)).to be_nil
    expect(described_class.extract(legacy_reserved.metadata)).to be_nil
    expect(legacy.metadata).to eq("custom" => true)
  end

  it "does not mistake unknown schema versions for current provenance" do
    metadata = {"_engram" => {"provenance" => {"version" => 2, "sources" => []}}}

    expect(described_class.extract(metadata)).to be_nil
  end
end
