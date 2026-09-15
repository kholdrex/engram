# frozen_string_literal: true

module Engram
  module UseCases
    # Deletes expired memories in bounded batches using one cutoff for the whole run.
    class ForgetExpired
      def initialize(store:)
        @store = store
      end

      def call(scope:, batch_size: 100, dry_run: false, now: Time.now)
        unless batch_size.is_a?(Integer) && batch_size.positive?
          raise ArgumentError, "batch_size must be a positive integer"
        end
        unless dry_run.equal?(true) || dry_run.equal?(false)
          raise ArgumentError, "dry_run must be true or false"
        end
        unless @store.respond_to?(:expired_ids) && @store.respond_to?(:delete_expired)
          raise Engram::Error, "forget_expired requires a store implementing expired_ids and delete_expired"
        end

        counts = {matched: 0, deleted: 0, dry_run: dry_run}
        payload = Engram::Instrumentation.payload(scope: scope, store: @store, **counts)
        Engram::Instrumentation.instrument("forget_expired", payload) do
          after_id = nil
          loop do
            ids = @store.expired_ids(scope: scope, at: now, limit: batch_size, after_id: after_id)
            break if ids.empty?
            raise Engram::Error, "expired_ids must advance its cursor" if ids.last == after_id

            counts[:matched] += ids.length
            counts[:deleted] += @store.delete_expired(scope: scope, ids: ids, at: now) unless dry_run
            payload.merge!(counts)
            after_id = ids.last
          end
          counts
        end
      rescue NotImplementedError
        raise Engram::Error, "forget_expired requires a store implementing expired_ids and delete_expired"
      end
    end
  end
end
