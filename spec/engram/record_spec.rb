# frozen_string_literal: true

RSpec.describe Engram::Record do
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

  it "rejects unknown memory kinds" do
    expect do
      described_class.new(content: "User likes tea", scope: "user:1", kind: :relationship)
    end.to raise_error(ArgumentError, /unknown memory kind/)
  end
end
