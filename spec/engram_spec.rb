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
      Engram.configure { |c| c.default_limit = 99 }
      Engram.reset!
      expect(Engram.config.default_limit).to eq(5)
    end
  end

  it "defaults to in-memory, network-free adapters" do
    expect(Engram.config.store).to be_a(Engram::Adapters::InMemoryStore)
    expect(Engram.config.embedder).to be_a(Engram::Adapters::NullEmbedder)
  end
end
