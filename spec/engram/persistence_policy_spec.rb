# frozen_string_literal: true

RSpec.describe Engram::PersistencePolicy do
  subject(:policy) { described_class.new }

  let(:embedder) { Engram::Adapters::NullEmbedder.new }

  def record(content, kind: :fact, metadata: {})
    Engram::Record.new(
      content: content,
      scope: "user:1",
      embedding: embedder.embed(content),
      kind: kind,
      metadata: metadata
    )
  end

  def provenance(alignment: :exact)
    Engram::Provenance.new(
      sources: [Engram::Provenance::Source.new(
        source_id: "message:1", source_type: "message", message_index: 0, role: "user",
        spans: [Engram::Provenance::Span.new(start_offset: 0, end_offset: 4)], alignment: alignment
      )],
      extractor: Engram::Provenance::Extractor.new(name: "host", model: "model-1"),
      confidence: 0.9
    )
  end

  it "allows durable user facts" do
    expect(policy.call(record("User prefers concise replies"))).to be_a(Engram::Record)
  end

  it "rejects obvious secrets" do
    expect(policy.call(record("User API key is sk-test-secret"))).to be_nil
  end

  it "allows safe policy statements about secrets" do
    persisted = policy.call(record("User says API keys must never be persisted"))

    expect(persisted.content).to eq("User says API keys must never be persisted")
  end

  it "rejects transient task progress" do
    expect(policy.call(record("User fixed the failing spec today"))).to be_nil
  end

  it "redacts configured denylist patterns before persistence" do
    policy = described_class.new(denylist_patterns: [/billing@example\.test/])

    persisted = policy.call(record("User billing email is billing@example.test"))

    expect(persisted.content).to eq("User billing email is [REDACTED]")
  end

  it "accepts absent and valid grounded provenance" do
    expect(policy.call(record("Legacy fact"))).to be_a(Engram::Record)
    metadata = Engram::Provenance.attach({}, provenance)
    expect(policy.call(record("Grounded fact", metadata: metadata))).to be_a(Engram::Record)
  end

  it "does not normalize or reject unrelated caller metadata" do
    metadata = {:host => 1, "host" => 2}

    expect(policy.call(record("Legacy fact", metadata: metadata)).metadata).to eq(metadata)
  end

  it "rejects provenance with any ungrounded source by default" do
    metadata = Engram::Provenance.attach({}, provenance(alignment: :ungrounded))

    expect(policy.call(record("Claim", metadata: metadata))).to be_nil
  end

  it "allows explicitly configured ungrounded provenance" do
    policy = described_class.new(allow_ungrounded: true)
    metadata = Engram::Provenance.attach({}, provenance(alignment: :ungrounded))

    expect(policy.call(record("Claim", metadata: metadata))).to be_a(Engram::Record)
  end

  it "raises rather than writing malformed or unsupported provenance" do
    malformed = {"_engram" => {"provenance" => {"version" => 1, "sources" => []}}}
    future = {"_engram" => {"provenance" => {"version" => 99}}}

    expect { policy.call(record("Claim", metadata: malformed)) }.to raise_error(Engram::Error, /malformed provenance/)
    expect { policy.call(record("Claim", metadata: future)) }.to raise_error(Engram::Error, /unsupported provenance/)
  end
end
