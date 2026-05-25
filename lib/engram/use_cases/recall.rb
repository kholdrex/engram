# frozen_string_literal: true

module Engram
  module UseCases
    # Embed a query and fetch the most relevant memories for a scope.
    class Recall
      def initialize(store:, embedder:)
        @store = store
        @embedder = embedder
      end

      # Returns Array<Record>, most relevant first.
      def call(query, scope:, limit: Engram.config.default_limit)
        raise ArgumentError, "query must be a non-empty string" if query.to_s.strip.empty?

        embedding = @embedder.embed(query)
        @store.search(embedding: embedding, scope: scope, limit: limit)
      end
    end
  end
end
