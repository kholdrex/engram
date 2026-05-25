# frozen_string_literal: true

module Engram
  module UseCases
    # Orchestrates a single observed turn: extract candidate facts, consolidate them
    # against existing memory, and apply the resulting decisions to the store.
    # Pure and synchronous — async execution is a Rails concern (see ObserveJob).
    class Observe
      def initialize(store:, extractor:, consolidator:)
        @store = store
        @extractor = extractor
        @consolidator = consolidator
      end

      # Returns the Array<Decision> that were applied.
      def call(messages:, scope:)
        candidates = @extractor.extract(messages: messages, scope: scope)
        return [] if candidates.empty?

        decisions = @consolidator.reconcile_all(candidates: candidates, scope: scope)
        decisions.each { |decision| apply(decision) }
        decisions
      end

      private

      def apply(decision)
        case decision.action
        when :add
          @store.add(decision.candidate)
        when :update
          @store.update(id: decision.target_id, record: decision.candidate) if decision.target_id
        when :forget
          @store.delete(id: decision.target_id) if decision.target_id
        when :noop
          nil
        end
      end
    end
  end
end
