# frozen_string_literal: true

RSpec.describe Engram::Record do
  it "uses its canonical state readers for hash serialization" do
    record = described_class.new(content: "User likes tea", scope: "user:1")

    expect(record.to_h.keys).to eq(described_class::STATE_READERS)
    expect(record.to_h).to eq(described_class::STATE_READERS.to_h do |reader|
      [reader, record.public_send(reader)]
    end)
  end

  it "uses fact as the default durable memory kind" do
    record = described_class.new(content: "User likes tea", scope: "user:1")

    expect(record.kind).to eq(:fact)
  end

  it "normalizes legacy semantic kind to fact" do
    record = described_class.new(content: "User likes tea", scope: "user:1", kind: "semantic")

    expect(record.kind).to eq(:fact)
  end

  it "accepts the supported memory kinds" do
    kinds = %i[fact preference instruction episodic]

    expect(kinds.map { |kind| described_class.new(content: "memory", scope: "user:1", kind: kind).kind })
      .to eq(kinds)
  end

  it "preserves timestamps when cloning with changed attributes" do
    created_at = Time.now - 60
    last_accessed_at = Time.now - 30
    record = described_class.new(
      content: "User likes tea",
      scope: "user:1",
      created_at: created_at,
      last_accessed_at: last_accessed_at
    )

    updated = record.with(content: "User likes coffee")

    expect(updated.created_at).to eq(created_at)
    expect(updated.last_accessed_at).to eq(last_accessed_at)
  end

  it "exposes structured provenance attached to a recalled record" do
    provenance = Engram::Provenance.new(
      sources: [
        Engram::Provenance::Source.new(
          source_id: "conversation:42",
          source_type: "conversation",
          message_index: 3,
          role: "user",
          spans: [Engram::Provenance::Span.new(start_offset: 6, end_offset: 15)],
          alignment: :exact
        )
      ],
      extractor: Engram::Provenance::Extractor.new(name: "host", model: "model-1"),
      confidence: 0.9
    )
    metadata = Engram::Provenance.attach({}, provenance)

    record = described_class.new(content: "User likes tea", scope: "user:1", metadata: metadata)

    expect(record.provenance).to eq(provenance)
    expect(record.provenance.sources.first.source_id).to eq("conversation:42")
  end

  it "returns nil provenance for legacy, malformed, and future records" do
    legacy = described_class.new(content: "Legacy", scope: "user:1")
    malformed = described_class.new(
      content: "Malformed",
      scope: "user:1",
      metadata: {"_engram" => {"provenance" => {"version" => 1, "sources" => []}}}
    )
    future = described_class.new(
      content: "Future",
      scope: "user:1",
      metadata: {"_engram" => {"provenance" => {"version" => 99}}}
    )

    expect([legacy.provenance, malformed.provenance, future.provenance]).to eq([nil, nil, nil])
  end

  it "rejects unknown memory kinds" do
    expect do
      described_class.new(content: "User likes tea", scope: "user:1", kind: :relationship)
    end.to raise_error(ArgumentError, /unknown memory kind/)
  end
end
