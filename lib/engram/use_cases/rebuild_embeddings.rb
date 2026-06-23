# frozen_string_literal: true

module Engram
  module UseCases
    # Rebuild stored embeddings when the active embedder configuration changes.
    # Returns counts useful for logging/observability:
    #   - :processed: total rows examined in scope
    #   - :updated: rows re-embedded and persisted
    #   - :skipped: rows skipped because they were unchanged or incomplete
    #   - :failed: row IDs that failed during rebuild
    class RebuildEmbeddings
      def initialize(store:, embedder:)
        @store = store
        @embedder = embedder
      end

      def call(scope:, stale_only: true, batch_size: 100)
        batch_size = Integer(batch_size)
        raise ArgumentError, "batch_size must be greater than 0" unless batch_size.positive?

        counts = {processed: 0, updated: 0, skipped: 0, failed: 0, failed_ids: []}

        @store.all(scope: scope)
          .each_slice(batch_size)
          .each do |batch|
            batch.each do |record|
              counts[:processed] += 1

              if record.id.nil?
                counts[:skipped] += 1
                next
              end

              if stale_only && !stale?(record)
                counts[:skipped] += 1
                next
              end

              begin
                rebuilt = record.with(embedding: @embedder.embed(record.content))
                rebuilt = EmbeddingMetadata.attach(rebuilt, embedder: @embedder)
                @store.update(id: record.id, record: rebuilt)
                counts[:updated] += 1
              rescue StandardError
                counts[:failed] += 1
                counts[:failed_ids] << record.id
              end
            end
          end

        {scope: scope, **counts}
      end

      private

      def stale?(record)
        stored = EmbeddingMetadata.extract(record.metadata)
        return true if stored.empty?

        expected = EmbeddingMetadata.for_embedder(@embedder, embedding: record.embedding)
        return true unless expected

        required = %w[adapter provider model dimensions fingerprint]
        return true if required.any? { |key| stored[key] != expected[key] }

        return true if
          stored["dimensions"] &&
          record.embedding.respond_to?(:length) &&
          record.embedding.length != stored["dimensions"].to_i

        false
      end
    end
  end
end
