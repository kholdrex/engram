# frozen_string_literal: true

module Engram
  module UseCases
    # Deletes every memory in a scope in id-ordered batches. Like Memory#forget, it bypasses
    # extraction, consolidation, and persistence hooks.
    class ForgetAll
      def initialize(store:)
        @store = store
      end

      def call(scope:, batch_size: 100, dry_run: false)
        unless batch_size.is_a?(Integer) && batch_size.positive?
          raise ArgumentError, "batch_size must be a positive integer"
        end
        unless dry_run.equal?(true) || dry_run.equal?(false)
          raise ArgumentError, "dry_run must be true or false"
        end

        counts = {matched: 0, deleted: 0, dry_run: dry_run}
        payload = Engram::Instrumentation.payload(scope: scope, store: @store, **counts)
        Engram::Instrumentation.instrument("forget_all", payload) do
          ids = []
          flush = lambda do
            counts[:matched] += ids.size
            payload.merge!(counts)
            unless dry_run
              delete(scope, ids) do |deleted|
                counts[:deleted] += deleted
                payload.merge!(counts)
              end
            end
            ids = []
          end
          EachMemory.new(store: @store).call(scope: scope, batch_size: batch_size) do |record|
            ids << record.id
            flush.call if ids.size == batch_size
          end
          flush.call unless ids.empty?
          counts
        end
      end

      private

      def delete(scope, ids)
        if @store.respond_to?(:delete_many)
          begin
            return yield @store.delete_many(scope: scope, ids: ids)
          rescue NotImplementedError
            # Optional capability: legacy adapters may inherit the default stub.
          end
        end

        ids.each { |id| yield @store.delete(scope: scope, id: id).to_i }
      end
    end
  end
end
