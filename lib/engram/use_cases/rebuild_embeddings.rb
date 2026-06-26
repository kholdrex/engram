# frozen_string_literal: true

module Engram
  module UseCases
    # Rebuild stored embeddings when the active embedder configuration changes.
    # Returns counts useful for logging/observability:
    #   - :processed: total rows examined in scope
    #   - :updated: rows re-embedded and persisted
    #   - :skipped: rows skipped because they were unchanged or incomplete
    #   - :failed: count of rows that failed during rebuild
    #   - :failed_ids: record IDs that failed during rebuild
    #   - :failed_errors: error class/message keyed by failed record ID
    class RebuildEmbeddings
      def initialize(store:, embedder:)
        @store = store
        @embedder = embedder
      end

      def call(scope:, stale_only: true, batch_size: 100)
        batch_size = Integer(batch_size)
        raise ArgumentError, "batch_size must be greater than 0" unless batch_size.positive?

        counts = {
          processed: 0,
          updated: 0,
          skipped: 0,
          failed: 0,
          failed_ids: [],
          failed_errors: {}
        }

        after_id = nil
        loop do
          batch = @store.all(scope: scope, limit: batch_size, after_id: after_id)
          break if batch.empty?

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
            rescue => error
              counts[:failed] += 1
              record_id = record.id
              counts[:failed_ids] << record_id
              counts[:failed_errors][record_id] = {
                class: error.class.name,
                message: error.message
              }
              warn "Rebuild failed for record ##{record_id}: #{error.class}: #{error.message}"
            end
          end

          after_id = batch.last.id
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

        return true if stored["dimensions"] &&
          record.embedding.respond_to?(:length) &&
          record.embedding.length != stored["dimensions"].to_i

        false
      end
    end
  end
end
