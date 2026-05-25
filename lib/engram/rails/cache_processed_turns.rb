# frozen_string_literal: true

module Engram
  module Rails
    # ProcessedTurns backed by Rails.cache. Idempotency survives across processes and job
    # retries when a shared cache (e.g. Solid Cache) is configured.
    class CacheProcessedTurns
      include Engram::Ports::ProcessedTurns

      def initialize(namespace: "engram:processed_turns", ttl: 86_400)
        @namespace = namespace
        @ttl = ttl
      end

      def seen?(key)
        ::Rails.cache.exist?(cache_key(key))
      end

      def record(key)
        ::Rails.cache.write(cache_key(key), true, expires_in: @ttl)
        key
      end

      private

      def cache_key(key)
        "#{@namespace}:#{key}"
      end
    end
  end
end
