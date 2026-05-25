# frozen_string_literal: true

RSpec.describe Engram::Adapters::InMemoryStore do
  subject(:store) { described_class.new }

  def rec(content, scope:, embedding:)
    Engram::Record.new(content: content, scope: scope, embedding: embedding)
  end

  it "adds and returns the record" do
    r = rec("a", scope: "u:1", embedding: [1.0, 0.0])
    expect(store.add(r)).to eq(r)
    expect(store.all(scope: "u:1")).to contain_exactly(r)
  end

  it "scopes search to the owner" do
    store.add(rec("mine", scope: "u:1", embedding: [1.0, 0.0]))
    store.add(rec("theirs", scope: "u:2", embedding: [1.0, 0.0]))

    results = store.search(embedding: [1.0, 0.0], scope: "u:1", limit: 5)
    expect(results.map(&:content)).to eq(["mine"])
  end

  it "orders by cosine similarity, nearest first" do
    store.add(rec("far", scope: "u:1", embedding: [0.0, 1.0]))
    store.add(rec("near", scope: "u:1", embedding: [1.0, 0.0]))

    results = store.search(embedding: [1.0, 0.0], scope: "u:1", limit: 2)
    expect(results.map(&:content)).to eq(["near", "far"])
  end

  it "respects the limit" do
    5.times { |i| store.add(rec("c#{i}", scope: "u:1", embedding: [1.0, i.to_f])) }
    expect(store.search(embedding: [1.0, 0.0], scope: "u:1", limit: 2).size).to eq(2)
  end

  it "assigns an id on add" do
    r = store.add(rec("a", scope: "u:1", embedding: [1.0, 0.0]))
    expect(r.id).not_to be_nil
  end

  it "updates an existing record by id" do
    r = store.add(rec("old", scope: "u:1", embedding: [1.0, 0.0]))
    store.update(id: r.id, record: rec("new", scope: "u:1", embedding: [0.0, 1.0]))
    expect(store.all(scope: "u:1").map(&:content)).to eq(["new"])
  end

  it "deletes a record by id" do
    r = store.add(rec("x", scope: "u:1", embedding: [1.0, 0.0]))
    store.delete(id: r.id)
    expect(store.all(scope: "u:1")).to be_empty
  end

  it "raises when updating a missing id" do
    expect { store.update(id: 999, record: rec("x", scope: "u:1", embedding: [1.0, 0.0])) }
      .to raise_error(Engram::Error)
  end

  it "touches last_accessed_at by id" do
    r = store.add(rec("x", scope: "u:1", embedding: [1.0, 0.0]))
    expect(r.last_accessed_at).to be_nil
    store.touch(id: r.id)
    expect(store.all(scope: "u:1").first.last_accessed_at).not_to be_nil
  end
end
