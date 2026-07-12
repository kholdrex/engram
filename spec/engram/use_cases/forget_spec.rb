# frozen_string_literal: true

RSpec.describe Engram::UseCases::Forget do
  subject(:forget) { described_class.new(store: store) }

  let(:store) { Engram::Adapters::InMemoryStore.new }
  let(:embedder) { Engram::Adapters::NullEmbedder.new }
  let(:day) { 24 * 60 * 60 }

  def seed(content, scope: "u:1", importance: 1.0, created_at: Time.now, last_accessed_at: nil)
    store.add(Engram::Record.new(content: content, scope: scope,
      embedding: embedder.embed(content), importance: importance,
      created_at: created_at, last_accessed_at: last_accessed_at))
  end

  it "forgets memories older than the cutoff" do
    seed("old", created_at: Time.now - (40 * day))
    seed("fresh", created_at: Time.now)

    forgotten = forget.call(scope: "u:1", older_than: 30 * day)
    expect(forgotten.map(&:content)).to eq(["old"])
    expect(store.all(scope: "u:1").map(&:content)).to eq(["fresh"])
  end

  it "keeps old memories at or above min_importance" do
    seed("old important", created_at: Time.now - (40 * day), importance: 0.9)
    seed("old trivial", created_at: Time.now - (40 * day), importance: 0.1)

    forget.call(scope: "u:1", older_than: 30 * day, min_importance: 0.5)
    expect(store.all(scope: "u:1").map(&:content)).to eq(["old important"])
  end

  it "uses last_accessed_at when present" do
    seed("recently used", created_at: Time.now - (40 * day), last_accessed_at: Time.now)
    expect(forget.call(scope: "u:1", older_than: 30 * day)).to be_empty
  end

  it "only affects the given scope" do
    seed("old other", scope: "u:2", created_at: Time.now - (40 * day))
    forget.call(scope: "u:1", older_than: 30 * day)
    expect(store.all(scope: "u:2").size).to eq(1)
  end

  it "cannot delete an out-of-scope row returned by a malicious store read" do
    victim = seed("old other", scope: "u:2", created_at: Time.now - (40 * day))
    allow(store).to receive(:all).and_call_original
    allow(store).to receive(:all).with(scope: "u:1").and_return([victim])

    forget.call(scope: "u:1", older_than: 30 * day)

    expect(store.all(scope: "u:2").map(&:content)).to eq(["old other"])
  end

  it "returns only records that were successfully deleted" do
    old = seed("old", created_at: Time.now - (40 * day))
    allow(store).to receive(:delete).with(scope: "u:1", id: old.id).and_return(0)

    expect(forget.call(scope: "u:1", older_than: 30 * day)).to be_empty
  end
end
