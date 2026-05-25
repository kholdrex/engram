# frozen_string_literal: true

module Engram
  module Adapters
    # In-process MemoryStore. Used as the zero-config default and in unit tests.
    # Search is exact cosine similarity over the stored vectors.
    class InMemoryStore
      include Ports::MemoryStore

      def initialize
        @records = {}
        @sequence = 0
      end

      def add(record)
        record.id ||= (@sequence += 1)
        @records[record.id] = record
        record
      end

      def search(embedding:, scope:, limit:)
        @records
          .values
          .select { |r| r.scope == scope && r.embedding }
          .map { |r| [r, Engram::Math.cosine_similarity(embedding, r.embedding)] }
          .sort_by { |(_, score)| -score }
          .first(limit)
          .map { |(record, _)| record }
      end

      def all(scope:)
        @records.values.select { |r| r.scope == scope }
      end

      def update(id:, record:)
        raise Engram::Error, "no memory with id #{id.inspect}" unless @records.key?(id)

        record.id = id
        @records[id] = record
      end

      def delete(id:)
        @records.delete(id)
      end

      def touch(id:, at: Time.now)
        record = @records[id]
        record.last_accessed_at = at if record
        record
      end

      def clear
        @records.clear
        @sequence = 0
      end
    end
  end
end
