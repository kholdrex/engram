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
end
