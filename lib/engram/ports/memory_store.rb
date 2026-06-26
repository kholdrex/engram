# frozen_string_literal: true

module Engram
  module Ports
    # Contract for a place memories are persisted and searched.
    # Implementations: Adapters::InMemoryStore, Adapters::PgvectorStore.
    module MemoryStore
      # Persist a Record. Returns the stored Record.
      def add(record)
        raise NotImplementedError, "#{self.class} must implement #add"
      end

      # Return up to `limit` Records in `scope` nearest to `embedding`,
      # ordered most-relevant first. When `kinds` is provided, only records with
      # those canonical memory kinds are eligible.
      def search(embedding:, scope:, limit:, kinds: nil, embedding_metadata: nil)
        raise NotImplementedError, "#{self.class} must implement #search"
      end

      # All Records for a scope (mostly for inspection/tests).
      # Supports optional `limit` and `offset` for batching large sweeps.
      # Returned records are sorted in stable `id` order when batching is used.
      # Use `after_id` for keyset pagination.
      def all(scope:, limit: nil, offset: 0, after_id: nil)
        raise NotImplementedError, "#{self.class} must implement #all"
      end

      # Replace the content/embedding of an existing memory. Used by consolidation
      # (UPDATE). Returns the updated Record.
      def update(id:, record:)
        raise NotImplementedError, "#{self.class} must implement #update"
      end

      # Remove a memory by id. Used by consolidation (FORGET).
      def delete(id:)
        raise NotImplementedError, "#{self.class} must implement #delete"
      end

      # Update the last-accessed timestamp of a memory. Used by recency-aware recall.
      def touch(id:, at: Time.now)
        raise NotImplementedError, "#{self.class} must implement #touch"
      end
    end
  end
end
