# frozen_string_literal: true

RSpec.describe Engram::UseCases::SourceImpact do
  subject(:source_impact) { described_class.new(store: store) }

  let(:store) { Engram::Adapters::InMemoryStore.new }
  let(:embedder) { Engram::Adapters::NullEmbedder.new }

  def provenance(sources)
    Engram::Provenance.new(
      sources: sources,
      extractor: Engram::Provenance::Extractor.new(name: "host", model: "model-1"),
      confidence: 0.9
    )
  end

  def source(source_id:, source_type:, role: "user", message_index: 0)
    Engram::Provenance::Source.new(
      source_id: source_id,
      source_type: source_type,
      message_index: message_index,
      role: role,
      spans: [Engram::Provenance::Span.new(start_offset: 0, end_offset: 1)],
      alignment: :exact
    )
  end

  def seed(content, scope: "u:1", metadata: {})
    record = Engram::Record.new(
      content: content, scope: scope, embedding: embedder.embed(content), metadata: metadata
    )
    store.add(record)
  end

  def seed_with_sources(content, sources, scope: "u:1")
    seed(content, scope: scope, metadata: Engram::Provenance.attach({}, provenance(sources)))
  end

  it "returns records whose provenance references the exact source id and type" do
    match = seed_with_sources("from convo", [source(source_id: "conversation:42", source_type: "conversation")])
    seed_with_sources("other id", [source(source_id: "conversation:7", source_type: "conversation")])

    results = source_impact.call(scope: "u:1", source_id: "conversation:42", source_type: "conversation")

    expect(results.map(&:content)).to eq(["from convo"])
    expect(results.first.id).to eq(match.id)
  end

  it "matches when at least one of several sources references the target" do
    seed_with_sources("multi", [
      source(source_id: "email:1", source_type: "email"),
      source(source_id: "conversation:42", source_type: "conversation", message_index: 1)
    ])

    results = source_impact.call(scope: "u:1", source_id: "conversation:42", source_type: "conversation")

    expect(results.map(&:content)).to eq(["multi"])
  end

  it "requires the source_type to match exactly" do
    seed_with_sources("wrong type", [source(source_id: "42", source_type: "conversation")])

    results = source_impact.call(scope: "u:1", source_id: "42", source_type: "email")

    expect(results).to be_empty
  end

  it "requires the source_id to match exactly (no prefix or trimming)" do
    seed_with_sources("padded id", [source(source_id: "conversation:42", source_type: "conversation")])

    expect(source_impact.call(scope: "u:1", source_id: " conversation:42 ", source_type: "conversation")).to be_empty
    expect(source_impact.call(scope: "u:1", source_id: "conversation:4", source_type: "conversation")).to be_empty
  end

  it "matches non-ASCII source identifiers exactly without Unicode normalization" do
    composed = "caf\u00E9"    # 'e' with acute as one codepoint U+00E9
    decomposed = "cafe\u0301" # 'e' + combining acute U+0301
    record = seed_with_sources("cafe note", [source(source_id: composed, source_type: "note")])

    expect(source_impact.call(scope: "u:1", source_id: composed, source_type: "note").map(&:id))
      .to eq([record.id])
    expect(source_impact.call(scope: "u:1", source_id: decomposed, source_type: "note")).to be_empty
  end

  it "does not cross scopes even when the same source id appears elsewhere" do
    seed_with_sources("mine", [source(source_id: "conversation:42", source_type: "conversation")], scope: "u:1")
    seed_with_sources("theirs", [source(source_id: "conversation:42", source_type: "conversation")], scope: "u:2")

    results = source_impact.call(scope: "u:1", source_id: "conversation:42", source_type: "conversation")

    expect(results.map(&:content)).to eq(["mine"])
  end

  it "treats legacy records with no provenance as non-matches" do
    seed("legacy", metadata: {"note" => "no provenance here"})

    expect(source_impact.call(scope: "u:1", source_id: "conversation:42", source_type: "conversation")).to be_empty
  end

  it "treats malformed provenance metadata as a non-match without raising" do
    seed("malformed", metadata: {"_engram" => {"provenance" => {"version" => 1, "sources" => "nope"}}})

    expect(source_impact.call(scope: "u:1", source_id: "conversation:42", source_type: "conversation")).to be_empty
  end

  it "treats future-schema provenance metadata as a non-match without raising" do
    seed("future", metadata: {"_engram" => {"provenance" => {"version" => 999, "sources" => []}}})

    expect(source_impact.call(scope: "u:1", source_id: "conversation:42", source_type: "conversation")).to be_empty
  end

  it "raises ArgumentError for a blank source_id" do
    expect { source_impact.call(scope: "u:1", source_id: "  ", source_type: "conversation") }
      .to raise_error(ArgumentError, /source_id/)
  end

  it "raises ArgumentError for a blank source_type" do
    expect { source_impact.call(scope: "u:1", source_id: "conversation:42", source_type: "") }
      .to raise_error(ArgumentError, /source_type/)
  end

  it "raises ArgumentError for non-String arguments" do
    expect { source_impact.call(scope: "u:1", source_id: 42, source_type: "conversation") }
      .to raise_error(ArgumentError, /source_id/)
    expect { source_impact.call(scope: "u:1", source_id: "conversation:42", source_type: :conversation) }
      .to raise_error(ArgumentError, /source_type/)
  end

  it "reads the scope through the store without mutating it" do
    seed_with_sources("kept", [source(source_id: "conversation:42", source_type: "conversation")])
    expect(store).not_to receive(:delete)
    expect(store).not_to receive(:add)
    expect(store).not_to receive(:touch)
    expect(store).not_to receive(:update)

    source_impact.call(scope: "u:1", source_id: "conversation:42", source_type: "conversation")

    expect(store.all(scope: "u:1").map(&:content)).to eq(["kept"])
  end
end
