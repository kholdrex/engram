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
      # ordered most-relevant first.
      def search(embedding:, scope:, limit:)
        raise NotImplementedError, "#{self.class} must implement #search"
      end

      # All Records for a scope (mostly for inspection/tests).
      def all(scope:)
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
    end
  end
end
