# frozen_string_literal: true

module Engram
  module Ports
    # Contract for remembering which turns have already been observed, so observation is
    # idempotent across retries and accidental double-calls.
    # Implementations: Adapters::InMemoryProcessedTurns, Rails::CacheProcessedTurns.
    module ProcessedTurns
      # Has this idempotency key already been processed?
      def seen?(key)
        raise NotImplementedError, "#{self.class} must implement #seen?"
      end

      # Mark this idempotency key as processed.
      def record(key)
        raise NotImplementedError, "#{self.class} must implement #record"
      end
    end
  end
end
