# frozen_string_literal: true

module Engram
  module UseCases
    # Embed a query and fetch the most relevant memories for a scope.
    #
    # By default this is pure vector similarity (the store's own ordering). When
    # importance_weight or recency_weight are non-zero, it fetches a larger candidate pool
    # and re-ranks by a composite score: similarity + importance + recency. With both
    # weights at zero (the default) behaviour is identical to plain similarity search.
    class Recall
      DEFAULT_HALFLIFE = 30 * 24 * 60 * 60 # 30 days, in seconds
      DEFAULT_POOL_FACTOR = 4

      def initialize(store:, embedder:, importance_weight: 0.0, recency_weight: 0.0,
        recency_halflife: DEFAULT_HALFLIFE, pool_factor: DEFAULT_POOL_FACTOR, touch: false)
        @store = store
        @embedder = embedder
        @importance_weight = importance_weight.to_f
        @recency_weight = recency_weight.to_f
        @recency_halflife = recency_halflife.to_f
        @pool_factor = pool_factor
        @touch = touch
      end

      # Returns Array<Record>, most relevant first.
      def call(query, scope:, limit: Engram.config.default_limit, kinds: nil)
        raise ArgumentError, "query must be a non-empty string" if query.to_s.strip.empty?

        payload = Engram::Instrumentation.payload(
          scope: scope,
          store: @store,
          limit: limit,
          kinds: Array(kinds).map(&:to_s),
          reranking: reranking?
        )
        Engram::Instrumentation.instrument("recall", payload) do
          embedding = @embedder.embed(query)
          pool_limit = reranking? ? limit * @pool_factor : limit
          pool = @store.search(embedding: embedding, scope: scope, limit: pool_limit, kinds: kinds)

          results = (reranking? ? rerank(pool, embedding) : pool).first(limit)
          touch(results) if @touch
          payload[:result_count] = results.size
          payload[:candidate_count] = pool.size
          results
        end
      end

      private

      def reranking?
        !@importance_weight.zero? || !@recency_weight.zero?
      end

      def rerank(records, query_embedding)
        now = Time.now
        records.sort_by do |record|
          similarity = Engram::Math.cosine_similarity(query_embedding, record.embedding)
          score = similarity +
            (@importance_weight * record.importance.to_f) +
            (@recency_weight * recency(record, now))
          -score
        end
      end

      def recency(record, now)
        timestamp = record.last_accessed_at || record.created_at
        return 0.0 unless timestamp

        age = now - timestamp
        0.5**(age / @recency_halflife)
      end

      def touch(records)
        records.each { |record| @store.touch(id: record.id, at: Time.now) if record.id }
      end
    end
  end
end
