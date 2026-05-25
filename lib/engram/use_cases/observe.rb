# frozen_string_literal: true

module Engram
  module UseCases
    # Orchestrates a single observed turn: extract candidate facts, consolidate them
    # against existing memory, and apply the resulting decisions to the store.
    # Pure and synchronous — async execution is a Rails concern (see ObserveJob).
    #
    # When a ProcessedTurns store and an idempotency_key are provided, a turn that was
    # already processed is skipped (no extraction, no duplicate memories).
    class Observe
      def initialize(store:, extractor:, consolidator:, processed_turns: nil, embedder: Engram.config.embedder)
        @store = store
        @extractor = extractor
        @consolidator = consolidator
        @processed_turns = processed_turns
        @embedder = embedder
      end

      # Returns the Array<Decision> that were applied (empty if skipped or nothing found).
      def call(messages:, scope:, idempotency_key: nil)
        return [] if already_processed?(idempotency_key)

        candidates = @extractor.extract(messages: messages, scope: scope)
        if candidates.empty?
          mark_processed(idempotency_key)
          return []
        end

        decisions = @consolidator.reconcile_all(candidates: candidates, scope: scope)
        decisions.each { |decision| apply(decision) }
        mark_processed(idempotency_key)
        decisions
      end

      private

      def already_processed?(key)
        !!(key && @processed_turns&.seen?(key))
      end

      def mark_processed(key)
        @processed_turns.record(key) if key && @processed_turns
      end

      def apply(decision)
        case decision.action
        when :add
          persist(:add, decision.candidate)
        when :update
          persist(:update, decision.candidate, id: decision.target_id) if decision.target_id
        when :forget
          @store.delete(id: decision.target_id) if decision.target_id
        when :noop
          nil
        end
      end

      def persist(action, record, id: nil)
        original_content = record.content
        record = Engram.config.before_persist.call(record) if Engram.config.before_persist
        record = Engram.config.persistence_policy.call(record) if record && Engram.config.persistence_policy
        return unless record

        record = record.with(embedding: @embedder.embed(record.content)) if record.content != original_content
        if action == :add
          @store.add(record)
        else
          @store.update(id: id, record: record)
        end
      end
    end
  end
end
