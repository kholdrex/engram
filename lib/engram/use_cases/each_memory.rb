# frozen_string_literal: true

module Engram
  module UseCases
    # Yields every memory in a scope in id order, loading at most batch_size records at a time.
    # Stores whose #all does not accept limit/after_id are read in one call.
    class EachMemory
      def initialize(store:)
        @store = store
      end

      def call(scope:, batch_size: 100, &block)
        unless batch_size.is_a?(Integer) && batch_size.positive?
          raise ArgumentError, "batch_size must be a positive integer"
        end
        unless keyset_supported?
          sort_by_id(@store.all(scope: scope)).each(&block)
          return nil
        end

        after_id = nil
        loop do
          batch = @store.all(scope: scope, limit: batch_size, after_id: after_id)
          break if batch.empty?
          unless batch.size <= batch_size && advances?(batch.map(&:id), after_id)
            raise Engram::Error, "store #all must return pages that advance by id"
          end

          batch.each(&block)
          after_id = batch.last.id
        end
        nil
      end

      private

      def advances?(ids, after_id)
        ids = [after_id, *ids] unless after_id.nil?
        ids.none?(&:nil?) && ids.each_cons(2).all? { |previous, current| previous < current }
      rescue ArgumentError, NoMethodError
        false
      end

      def sort_by_id(records)
        records.sort_by(&:id)
      rescue ArgumentError, NoMethodError
        raise Engram::Error, "store #all returned ids that cannot be ordered"
      end

      def keyset_supported?
        keywords = @store.method(:all).parameters.filter_map { |kind, name| name if %i[key keyreq].include?(kind) }
        keywords.include?(:limit) && keywords.include?(:after_id)
      end
    end
  end
end
