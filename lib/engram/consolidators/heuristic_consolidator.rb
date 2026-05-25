# frozen_string_literal: true

module Engram
  module Consolidators
    # Deterministic, no-LLM consolidation. ADDs a candidate unless a near-duplicate
    # already exists (then NOOP). It cannot detect contradictions or updates — that is the
    # LLMConsolidator's job. Useful as the default in tests and as a zero-cost fallback.
    class HeuristicConsolidator
      include Ports::Consolidator

      def initialize(store:, similarity_threshold: 0.97)
        @store = store
        @similarity_threshold = similarity_threshold
      end

      def reconcile_all(candidates:, scope:)
        Array(candidates).map do |candidate|
          nearest = @store.search(embedding: candidate.embedding, scope: scope, limit: 1).first
          similarity = nearest ? Engram::Math.cosine_similarity(candidate.embedding, nearest.embedding) : 0.0

          if nearest && similarity >= @similarity_threshold
            Engram::Decision.new(action: :noop, candidate: candidate,
              reason: "near-duplicate (sim=#{similarity.round(3)})")
          else
            Engram::Decision.new(action: :add, candidate: candidate)
          end
        end
      end
    end
  end
end
