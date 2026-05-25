# frozen_string_literal: true

module Engram
  # Holds the wired adapters and defaults. Out of the box everything works in memory,
  # so the gem is usable (and testable) with zero infrastructure. In a Rails app the
  # initializer typically swaps in PgvectorStore + RubyLLMEmbedder + RubyLLMCompletion.
  class Configuration
    attr_accessor :store, :embedder, :completion, :default_limit,
      :consolidator, :extraction_min_confidence

    def initialize
      @store = Adapters::InMemoryStore.new
      @embedder = Adapters::NullEmbedder.new
      @completion = nil # required for observe (extract/consolidate); nil until configured
      @default_limit = 5
      @consolidator = :heuristic # :heuristic (deterministic) or :llm (LLM-as-judge)
      @extraction_min_confidence = 0.5
    end
  end
end
