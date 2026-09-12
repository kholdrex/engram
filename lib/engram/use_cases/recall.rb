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
      def call(query, scope:, limit: Engram.config.default_limit, kinds: nil, min_similarity: nil)
        raise ArgumentError, "query must be a non-empty string" if query.to_s.strip.empty?
        unless limit.is_a?(Integer) && limit >= 0
          raise ArgumentError, "limit must be a non-negative integer"
        end
        validate_min_similarity!(min_similarity)

        payload = Engram::Instrumentation.payload(
          scope: scope,
          store: @store,
          limit: limit,
          kinds: Array(kinds).map(&:to_s),
          reranking: reranking?,
          min_similarity: min_similarity,
          candidate_count: 0,
          filtered_count: 0,
          result_count: 0
        )
        Engram::Instrumentation.instrument("recall", payload) do
          next [] if limit.zero?

          embedding = @embedder.embed(query)
          embedding_metadata = Engram::EmbeddingMetadata.for_embedder(@embedder, embedding: embedding)
          pool_limit = reranking? ? limit * @pool_factor : limit
          pool = Engram::EmbeddingMetadata.search(
            @store,
            embedding: embedding,
            embedding_metadata: embedding_metadata,
            scope: scope,
            limit: pool_limit,
            kinds: kinds
          )

          candidates = if min_similarity.nil?
            pool
          else
            pool.select { |record| meets_similarity?(record.embedding, embedding, min_similarity) }
          end
          results = (reranking? ? rerank(candidates, embedding) : candidates).first(limit)
          touch(results, scope) if @touch
          payload[:result_count] = results.size
          payload[:candidate_count] = pool.size
          payload[:filtered_count] = pool.size - candidates.size
          results
        end
      end

      private

      def validate_min_similarity!(value)
        return if value.nil?
        return if value.is_a?(Numeric) && value.real? && value.finite? && value.between?(-1, 1)

        raise ArgumentError, "min_similarity must be a finite number between -1 and 1, or nil"
      end

      def meets_similarity?(embedding, query_embedding, minimum)
        return false unless comparable_vector?(embedding) && comparable_vector?(query_embedding)
        return false unless embedding.length == query_embedding.length

        similarity = Engram::Math.cosine_similarity(query_embedding, embedding)
        similarity.finite? && similarity.clamp(-1.0, 1.0) >= minimum
      end

      def comparable_vector?(vector)
        vector.is_a?(Array) && !vector.empty? &&
          vector.all? { |value| value.is_a?(Numeric) && value.real? && value.finite? } &&
          vector.any? { |value| !value.zero? }
      end

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

      def touch(records, scope)
        records.each { |record| @store.touch(scope: scope, id: record.id, at: Time.now) if record.id }
      end
    end
  end
end
