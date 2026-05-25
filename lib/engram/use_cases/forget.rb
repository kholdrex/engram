# frozen_string_literal: true

module Engram
  module UseCases
    # Prune stale memories from a scope. A memory is stale when its last activity
    # (last_accessed_at, or created_at if never accessed) is older than the cutoff.
    # `min_importance` keeps important memories even when they are old: only memories with
    # importance below it are eligible. The default forgets all stale memories.
    class Forget
      def initialize(store:)
        @store = store
      end

      # Returns the Array<Record> that were forgotten.
      def call(scope:, older_than:, min_importance: Float::INFINITY, now: Time.now)
        cutoff = now - older_than

        stale = @store.all(scope: scope).select do |record|
          timestamp = record.last_accessed_at || record.created_at
          timestamp && timestamp < cutoff && record.importance.to_f < min_importance
        end

        stale.each { |record| @store.delete(id: record.id) if record.id }
        stale
      end
    end
  end
end
