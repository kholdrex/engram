# frozen_string_literal: true

require_relative "../../../lib/engram/rails/cache_processed_turns"

atomic_fake_cache_class = Class.new do
  def initialize
    @data = {}
    @mutex = Mutex.new
  end

  def exist?(key)
    @mutex.synchronize { @data.key?(key) }
  end

  def write(key, value, expires_in: nil, unless_exist: false)
    @mutex.synchronize do
      return false if unless_exist && @data.key?(key)

      @data[key] = value
      true
    end
  end

  def read(key)
    @mutex.synchronize { @data[key] }
  end

  def delete(key)
    @mutex.synchronize { @data.delete(key) }
  end
end

RSpec.describe Engram::Rails::CacheProcessedTurns do
  subject(:store) { described_class.new(cache: cache, lease_ttl: 60) }

  let(:cache) { atomic_fake_cache_class.new }

  it "uses atomic claims and separate scoped completion state" do
    first = store.claim(scope: "u:1", key: "same")
    expect(first).not_to be_nil
    expect(store.claim(scope: "u:1", key: "same")).to be_nil
    expect(store.claim(scope: "u:2", key: "same")).not_to be_nil

    store.complete(scope: "u:1", key: "same", claim: first)
    expect(store.completed?(scope: "u:1", key: "same")).to be(true)
    expect(store.claim(scope: "u:1", key: "same")).to be_nil
    keys = cache.instance_variable_get(:@data).keys
    expect(keys.any? { |key| key.include?(":completed:") }).to be(true)
    expect(keys.any? { |key| key.include?(":claim:") }).to be(true)
  end

  it "grants exactly one claim under thread contention" do
    ready = Queue.new
    start = Queue.new
    threads = 8.times.map do
      Thread.new do
        ready << true
        start.pop
        store.claim(scope: "u:1", key: "turn")
      end
    end
    8.times { ready.pop }
    8.times { start << true }
    expect(threads.map(&:value).compact.size).to eq(1)
  end

  it "rejects a backend that cannot report atomic unless-exist writes" do
    cache = Object.new
    cache.define_singleton_method(:exist?) { |_key| false }
    cache.define_singleton_method(:write) { |*_args, **_kwargs| nil }
    non_atomic_store = described_class.new(cache: cache)

    expect { non_atomic_store.claim(scope: "u:1", key: "turn") }
      .to raise_error(described_class::NonAtomicCacheError)
  end

  it "rejects a truthy non-boolean result from an unless-exist write" do
    allow(cache).to receive(:write).and_return("stored")

    expect { store.claim(scope: "u:1", key: "turn") }
      .to raise_error(described_class::NonAtomicCacheError)
  end

  it "uses stable length-prefixed UTF-8 scope and key namespacing" do
    store.claim(scope: "u:é", key: "turn")
    store.claim(scope: "u:éturn", key: "")

    keys = cache.instance_variable_get(:@data).keys
    expect(keys).to include(
      "engram:processed_turns:claim:e0ba65fd9c68099b59bfc17f89fd805a0734d8d64931086ea6b5409a78e6b998"
    )
    expect(keys.grep(/:claim:/).uniq.size).to eq(2)
  end

  it "returns no claim when completion appears during the claim race" do
    completion_checks = 0
    allow(cache).to receive(:exist?).and_wrap_original do |original, key|
      if key.include?(":completed:")
        completion_checks += 1
        next true if completion_checks == 2
      end
      original.call(key)
    end

    expect(store.claim(scope: "u:1", key: "turn")).to be_nil
    expect(cache.instance_variable_get(:@data).keys.grep(/:claim:/).size).to eq(1)
  end

  it "passes the configured lease and completion TTLs to cache writes" do
    ttl_store = described_class.new(cache: cache, lease_ttl: 7, ttl: 41)
    allow(cache).to receive(:write).and_call_original
    claim = ttl_store.claim(scope: "u:1", key: "turn")
    ttl_store.complete(scope: "u:1", key: "turn", claim: claim)

    expect(cache).to have_received(:write).with(anything, claim, expires_in: 7, unless_exist: true)
    expect(cache).to have_received(:write).with(anything, true, expires_in: 41)
  end

  it "does not let stale release delete a successor claim after lease turnover" do
    stale = store.claim(scope: "u:1", key: "turn")
    claim_key = cache.instance_variable_get(:@data).keys.find { |key| key.include?(":claim:") }
    cache.delete(claim_key) # deterministically model lease expiry
    successor = store.claim(scope: "u:1", key: "turn")

    store.release(scope: "u:1", key: "turn", claim: stale)

    expect(cache.read(claim_key)).to eq(successor)
    expect(store.claim(scope: "u:1", key: "turn")).to be_nil
  end

  it "records stale successful completion without deleting a successor claim" do
    stale = store.claim(scope: "u:1", key: "turn")
    claim_key = cache.instance_variable_get(:@data).keys.find { |key| key.include?(":claim:") }
    cache.delete(claim_key) # deterministically model lease expiry
    successor = store.claim(scope: "u:1", key: "turn")

    expect(store.complete(scope: "u:1", key: "turn", claim: stale)).to be(true)

    expect(cache.read(claim_key)).to eq(successor)
    expect(store.completed?(scope: "u:1", key: "turn")).to be(true)
    expect(store.claim(scope: "u:1", key: "turn")).to be_nil
  end

  it "leaves its lease to expire when work is released" do
    claim = store.claim(scope: "u:1", key: "turn")
    store.release(scope: "u:1", key: "turn", claim: claim)

    expect(store.claim(scope: "u:1", key: "turn")).to be_nil
  end
end
