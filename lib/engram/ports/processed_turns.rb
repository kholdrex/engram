# frozen_string_literal: true

module Engram
  module Ports
    # Scoped lifecycle for observation idempotency. Implementations suppress concurrent claims
    # while a lease is live. Lease expiry may permit overlap; this contract does not provide
    # token ownership, fencing, or exactly-once execution.
    # #claim returns a truthy opaque token when the caller may proceed, or nil when suppressed.
    # Implementations: Adapters::InMemoryProcessedTurns, Rails::CacheProcessedTurns.
    module ProcessedTurns
      def claim(scope:, key:)
        raise NotImplementedError, "#{self.class} must implement #claim"
      end

      def complete(scope:, key:, claim:)
        raise NotImplementedError, "#{self.class} must implement #complete"
      end

      def release(scope:, key:, claim:)
        raise NotImplementedError, "#{self.class} must implement #release"
      end

      def completed?(scope:, key:)
        raise NotImplementedError, "#{self.class} must implement #completed?"
      end
    end
  end
end
