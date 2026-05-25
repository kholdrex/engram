# frozen_string_literal: true

RSpec.describe Engram::Adapters::InMemoryProcessedTurns do
  subject(:store) { described_class.new }

  it "reports a key as unseen until recorded" do
    expect(store.seen?("abc")).to be(false)
    store.record("abc")
    expect(store.seen?("abc")).to be(true)
  end

  it "tracks keys independently" do
    store.record("abc")
    expect(store.seen?("xyz")).to be(false)
  end

  it "clears recorded keys" do
    store.record("abc")
    store.clear
    expect(store.seen?("abc")).to be(false)
  end
end
