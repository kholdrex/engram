# frozen_string_literal: true

require "spec_helper"

RSpec.describe Engram::Internal::CoreHash do
  # A String subclass whose comparison/hash hooks raise. Ruby 3.4's Hash#each_pair
  # can invoke a key's #eql? while iterating a table left in a delete-then-insert
  # collision state, which would run this code. CoreHash.each_pair must never touch
  # a key's #hash/#eql?/#== regardless of the table's internal layout.
  def hostile_key_class
    Class.new(String) do
      def ==(_other) = raise("hostile ==")
      def eql?(_other) = raise("hostile eql?")
      def hash = raise("hostile hash")
    end
  end

  it "yields every stored pair in insertion order" do
    pairs = []
    Engram::Internal::CoreHash.each_pair({"a" => 1, "b" => 2, "c" => 3}) do |key, value|
      pairs << [key, value]
    end

    expect(pairs).to eq([["a", 1], ["b", 2], ["c", 3]])
  end

  it "iterates without dispatching through a hostile key's comparison or hash hooks" do
    key = hostile_key_class.new("version")
    # Reproduce the pathological delete-then-insert table shape from the adversarial
    # provenance payload, which can make a raw Hash#each_pair call key.eql?.
    payload = {"version" => 1, "sources" => 2, "extractor" => 3, "confidence" => 4}
    payload[key] = payload.delete("version")

    seen = []
    expect do
      Engram::Internal::CoreHash.each_pair(payload) { |k, v| seen << v }
    end.not_to raise_error
    expect(seen).to contain_exactly(1, 2, 3, 4)
  end

  it "reads through the core Hash implementation, ignoring subclass overrides" do
    subclass = Class.new(Hash) do
      def keys = raise("subclass keys override must not run")
      def values = raise("subclass values override must not run")
      def each_pair = raise("subclass each_pair override must not run")
    end
    hash = subclass.new
    hash["k"] = "v"

    pairs = []
    Engram::Internal::CoreHash.each_pair(hash) { |k, v| pairs << [k, v] }

    expect(pairs).to eq([["k", "v"]])
  end
end
