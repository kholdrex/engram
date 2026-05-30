# frozen_string_literal: true

module Engram
  # Holds the wired adapters and defaults. Out of the box everything works in memory,
  # so the gem is usable (and testable) with zero infrastructure. In a Rails app the
  # initializer typically swaps in PgvectorStore + RubyLLMEmbedder + RubyLLMCompletion.
  class Configuration
    attr_accessor :store, :embedder, :completion, :default_limit,
      :consolidator, :extraction_min_confidence, :processed_turns,
      :importance_weight, :recency_weight, :recency_halflife, :touch_on_recall,
      :persistence_policy, :before_persist, :instrumentation_scope_identifier

    def initialize
      @store = Adapters::InMemoryStore.new
      @embedder = Adapters::NullEmbedder.new
      @completion = nil # required for observe (extract/consolidate); nil until configured
      @default_limit = 5
      @consolidator = :heuristic # :heuristic (deterministic) or :llm (LLM-as-judge)
      @extraction_min_confidence = 0.5
      @processed_turns = Adapters::InMemoryProcessedTurns.new # idempotency for observe
      @persistence_policy = PersistencePolicy.new
      @before_persist = nil
      @instrumentation_scope_identifier = nil

      # Recall ranking. With both weights at 0.0, recall is plain similarity search.
      @importance_weight = 0.0
      @recency_weight = 0.0
      @recency_halflife = UseCases::Recall::DEFAULT_HALFLIFE
      @touch_on_recall = false
    end
  end
end
