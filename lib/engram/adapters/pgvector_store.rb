# frozen_string_literal: true

module Engram
  module Adapters
    # MemoryStore backed by PostgreSQL + pgvector via the `neighbor` gem.
    #
    # Requires the host app to provide ActiveRecord, the `neighbor` gem, and an AR model
    # (default: Engram::MemoryRecord) created by the install generator. These are NOT hard
    # dependencies of engram; this adapter only references them at call time.
    class PgvectorStore
      include Ports::MemoryStore

      def initialize(model: nil)
        @model = model
      end

      def add(record)
        row = model.create!(
          content: record.content,
          scope: record.scope,
          kind: record.kind.to_s,
          importance: record.importance,
          metadata: record.metadata,
          embedding: record.embedding
        )
        to_record(row)
      end

      def search(embedding:, scope:, limit:)
        model
          .where(scope: scope)
          .nearest_neighbors(:embedding, embedding, distance: "cosine")
          .limit(limit)
          .map { |row| to_record(row) }
      end

      def all(scope:)
        model.where(scope: scope).map { |row| to_record(row) }
      end

      def update(id:, record:)
        row = model.find(id)
        row.update!(
          content: record.content,
          kind: record.kind.to_s,
          importance: record.importance,
          metadata: record.metadata,
          embedding: record.embedding
        )
        to_record(row)
      end

      def delete(id:)
        model.where(id: id).delete_all
      end

      def touch(id:, at: Time.now)
        model.where(id: id).update_all(last_accessed_at: at)
      end

      private

      def model
        @model ||= resolve_default_model
      end

      def resolve_default_model
        unless defined?(Engram::MemoryRecord)
          raise Engram::Error,
            "PgvectorStore needs an ActiveRecord model. Run the install generator or pass `model:`."
        end
        Engram::MemoryRecord
      end

      def to_record(row)
        Engram::Record.new(
          id: row.id,
          content: row.content,
          scope: row.scope,
          embedding: row.embedding,
          kind: (row.kind || :semantic).to_sym,
          importance: row.importance || 1.0,
          metadata: row.metadata || {},
          created_at: row.created_at,
          last_accessed_at: row.try(:last_accessed_at)
        )
      end
    end
  end
end
