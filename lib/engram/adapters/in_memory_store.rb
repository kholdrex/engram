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
        validate_scope!(record.scope)

        record.id ||= (@sequence += 1)
        @records[record.id] = record
        record
      end

      def search(embedding:, scope:, limit:, kinds: nil, embedding_metadata: nil)
        Engram::EmbeddingMetadata.validate_query!(embedding, embedding_metadata)
        allowed_kinds = normalize_kinds(kinds)

        results = @records
          .values
          .select { |r| searchable?(r, scope, allowed_kinds) }
          .map { |r| [r, Engram::Math.cosine_similarity(embedding, r.embedding)] }
          .sort_by { |(_, score)| -score }
          .first(limit)
          .map { |(record, _)| record }

        results.each { |record| Engram::EmbeddingMetadata.validate_record!(record, embedding, embedding_metadata) }
        results
      end

      def all(scope:, limit: nil, offset: 0, after_id: nil)
        records = @records.values.select { |r| r.scope == scope }.sort_by { |record| record.id }
        records = records.drop_while { |record| !after_id.nil? && record.id && record.id <= after_id }
        records = records.drop(offset) if offset > 0
        records = records.take(limit) if limit
        records
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

      private

      def validate_scope!(scope)
        raise Engram::Error, "memory scope cannot be nil" if scope.nil?
      end

      def searchable?(record, scope, allowed_kinds)
        record.scope == scope && record.embedding && (allowed_kinds.nil? || allowed_kinds.include?(record.kind))
      end

      def normalize_kinds(kinds)
        return nil if kinds.nil?

        values = Array(kinds)
        return nil if values.empty?

        values.map { |kind| Engram::MemoryKind.normalize(kind) }
      end
    end
  end
end
