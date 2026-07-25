# frozen_string_literal: true

RSpec.describe Engram::UseCases::GroundingReport do
  subject(:grounding_report) { described_class.new(store: store) }

  let(:store) { Engram::Adapters::InMemoryStore.new }
  let(:embedder) { Engram::Adapters::NullEmbedder.new }

  def source(alignment)
    Engram::Provenance::Source.new(
      source_id: "conversation:42",
      source_type: "conversation",
      message_index: 0,
      role: "user",
      spans: [Engram::Provenance::Span.new(start_offset: 0, end_offset: 1)],
      alignment: alignment
    )
  end

  def provenance(*alignments)
    Engram::Provenance.new(
      sources: alignments.map { |alignment| source(alignment) },
      extractor: Engram::Provenance::Extractor.new(name: "host", model: "model-1"),
      confidence: 0.9
    )
  end

  def seed(content, scope: "u:1", metadata: {})
    store.add(Engram::Record.new(
      content: content,
      scope: scope,
      embedding: embedder.embed(content),
      metadata: metadata
    ))
  end

  def seed_with_provenance(content, *alignments, scope: "u:1")
    seed(content, scope: scope, metadata: Engram::Provenance.attach({}, provenance(*alignments)))
  end

  it "counts all four single-source alignment buckets separately" do
    %i[exact normalized inferred ungrounded].each do |alignment|
      seed_with_provenance(alignment.to_s, alignment)
    end

    expect(grounding_report.call(scope: "u:1")).to eq(
      exact: 1, normalized: 1, inferred: 1, ungrounded: 1, unattributed: 0, total: 4
    )
  end

  it "classifies a mixed-source record by its weakest alignment" do
    seed_with_provenance("mixed", :exact, :inferred, :normalized)

    expect(grounding_report.call(scope: "u:1")).to eq(
      exact: 0, normalized: 0, inferred: 1, ungrounded: 0, unattributed: 0, total: 1
    )
  end

  it "counts legacy, malformed, and future-schema provenance as unattributed" do
    seed("legacy", metadata: {"note" => "no provenance"})
    seed("malformed", metadata: {"_engram" => {"provenance" => {"version" => 1, "sources" => "nope"}}})
    seed("future", metadata: {"_engram" => {"provenance" => {"version" => 999, "sources" => []}}})

    expect(grounding_report.call(scope: "u:1")).to eq(
      exact: 0, normalized: 0, inferred: 0, ungrounded: 0, unattributed: 3, total: 3
    )
  end

  it "counts only records in the requested scope" do
    seed_with_provenance("mine", :normalized, scope: "u:1")
    seed_with_provenance("theirs", :ungrounded, scope: "u:2")
    seed("their legacy", scope: "u:2")

    expect(grounding_report.call(scope: "u:1")).to eq(
      exact: 0, normalized: 1, inferred: 0, ungrounded: 0, unattributed: 0, total: 1
    )
  end

  it "returns every bucket at zero for an empty scope" do
    expect(grounding_report.call(scope: "empty")).to eq(
      exact: 0, normalized: 0, inferred: 0, ungrounded: 0, unattributed: 0, total: 0
    )
  end

  it "returns a frozen hash with exactly the public keys" do
    result = grounding_report.call(scope: "u:1")

    expect(result).to be_frozen
    expect(result.keys).to contain_exactly(:exact, :normalized, :inferred, :ungrounded, :unattributed, :total)
    expect(result.values).to all(be_a(Integer).and(be >= 0))
  end
end
