# frozen_string_literal: true

RSpec.describe Engram do
  it "has a semver version" do
    expect(Engram::VERSION).to match(/\A\d+\.\d+\.\d+\z/)
  end

  describe ".configure" do
    it "yields the configuration" do
      Engram.configure { |c| c.default_limit = 10 }
      expect(Engram.config.default_limit).to eq(10)
    end
  end

  describe ".reset!" do
    it "restores defaults" do
      Engram.configure do |c|
        c.default_limit = 99
        c.recall_min_similarity = 0.5
        c.injection_max_bytes = 8_000
      end
      Engram.reset!
      expect(Engram.config.default_limit).to eq(5)
      expect(Engram.config.recall_min_similarity).to be_nil
      expect(Engram.config.injection_max_bytes).to be_nil
    end
  end

  it "defaults to in-memory, network-free adapters" do
    expect(Engram.config.store).to be_a(Engram::Adapters::InMemoryStore)
    expect(Engram.config.embedder).to be_a(Engram::Adapters::NullEmbedder)
  end
end
