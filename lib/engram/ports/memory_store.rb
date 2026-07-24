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

      # Optional performance capability: return the subset of requested ids that
      # exists in `scope`, preserving each requested value's representation rather
      # than returning a store-native cast of it. Return at most one requested
      # representation for each persisted record when the store accepts aliases.
      # Callers must fall back
      # to #all for legacy stores that do not expose this method or leave it
      # unimplemented, so adding it does not break custom MemoryStore adapters.
      def existing_ids(scope:, ids:)
        raise NotImplementedError, "#{self.class} does not implement #existing_ids"
      end

      # Replace the content/embedding of an existing memory. Used by consolidation
      # (UPDATE). Returns the updated Record. Raises Engram::Error when the scoped
      # record does not exist or the replacement would move it to another scope.
      def update(scope:, id:, record:)
        raise NotImplementedError, "#{self.class} must implement #update"
      end

      # Remove a memory by id. Used by consolidation (FORGET). Returns the number
      # of affected rows: 1 when deleted, 0 when the scoped record does not exist.
      def delete(scope:, id:)
        raise NotImplementedError, "#{self.class} must implement #delete"
      end

      # Update the last-accessed timestamp of a memory. Used by recency-aware recall.
      # Returns the number of affected rows: 1 when touched, 0 when the scoped record
      # does not exist.
      def touch(scope:, id:, at: Time.now)
        raise NotImplementedError, "#{self.class} must implement #touch"
      end
    end
  end
end
