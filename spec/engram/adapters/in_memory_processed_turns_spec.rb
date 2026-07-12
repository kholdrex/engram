# frozen_string_literal: true

RSpec.describe Engram::Adapters::InMemoryProcessedTurns do
  subject(:store) { described_class.new }

  it "claims, completes, and permanently suppresses a scoped key" do
    claim = store.claim(scope: "u:1", key: "abc")
    expect(claim).not_to be_nil
    expect(store.claim(scope: "u:1", key: "abc")).to be_nil
    store.complete(scope: "u:1", key: "abc", claim: claim)
    expect(store.completed?(scope: "u:1", key: "abc")).to be(true)
    expect(store.claim(scope: "u:1", key: "abc")).to be_nil
  end

  it "does not collide the same raw key across scopes" do
    expect(store.claim(scope: "u:1", key: "abc")).not_to be_nil
    expect(store.claim(scope: "u:2", key: "abc")).not_to be_nil
  end

  it "releases an owned claim for retry" do
    claim = store.claim(scope: "u:1", key: "abc")
    store.release(scope: "u:1", key: "abc", claim: claim)
    expect(store.claim(scope: "u:1", key: "abc")).not_to be_nil
  end

  it "allows retry after an abandoned claim lease expires" do
    now = 10.0
    leased_store = described_class.new(lease_ttl: 5, clock: -> { now })
    expect(leased_store.claim(scope: "u:1", key: "abc")).not_to be_nil
    expect(leased_store.claim(scope: "u:1", key: "abc")).to be_nil
    now = 15.0
    expect(leased_store.claim(scope: "u:1", key: "abc")).not_to be_nil
  end

  it "atomically grants one claim under thread contention" do
    ready = Queue.new
    start = Queue.new
    threads = 8.times.map do
      Thread.new do
        ready << true
        start.pop
        store.claim(scope: "u:1", key: "abc")
      end
    end
    8.times { ready.pop }
    8.times { start << true }
    expect(threads.map(&:value).compact.size).to eq(1)
  end

  it "clears claims and completions" do
    claim = store.claim(scope: "u:1", key: "abc")
    store.complete(scope: "u:1", key: "abc", claim: claim)
    store.clear
    expect(store.claim(scope: "u:1", key: "abc")).not_to be_nil
  end
end
