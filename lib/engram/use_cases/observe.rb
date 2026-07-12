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
        payload = Engram::Instrumentation.payload(
          scope: scope,
          store: @store,
          message_count: messages.size,
          idempotency_key_present: !idempotency_key.nil?
        )
        Engram::Instrumentation.instrument("observe", payload) do
          claim = acquire_claim(scope, idempotency_key)
          if idempotency_key && @processed_turns && !claim
            payload[:skipped] = true
            payload[:candidate_count] = 0
            payload[:decision_count] = 0
            next []
          end

          begin
            candidates = extract(messages: messages, scope: scope)
            payload[:candidate_count] = candidates.size
            if candidates.empty?
              complete_claim(scope, idempotency_key, claim)
              payload[:decision_count] = 0
              next []
            end

            decisions = consolidate(candidates: candidates, scope: scope)
            applied_decisions = decisions.filter_map { |decision| apply(decision, scope) }
            payload[:decision_count] = applied_decisions.size
            payload[:decision_actions] = applied_decisions.map { |decision| decision.action.to_s }
            complete_claim(scope, idempotency_key, claim)
            applied_decisions
          rescue
            release_claim(scope, idempotency_key, claim)
            raise
          end
        end
      end

      private

      def acquire_claim(scope, key)
        @processed_turns.claim(scope: scope, key: key) if key && @processed_turns
      end

      def complete_claim(scope, key, claim)
        @processed_turns.complete(scope: scope, key: key, claim: claim) if claim
      end

      def release_claim(scope, key, claim)
        @processed_turns.release(scope: scope, key: key, claim: claim) if claim
      end

      def extract(messages:, scope:)
        payload = Engram::Instrumentation.payload(scope: scope, store: @store, message_count: messages.size)
        Engram::Instrumentation.instrument("extract", payload) do
          candidates = @extractor.extract(messages: messages, scope: scope)
          payload[:candidate_count] = candidates.size
          candidates
        end
      end

      def consolidate(candidates:, scope:)
        payload = Engram::Instrumentation.payload(scope: scope, store: @store, candidate_count: candidates.size)
        Engram::Instrumentation.instrument("consolidate", payload) do
          decisions = @consolidator.reconcile_all(candidates: candidates, scope: scope)
          payload[:decision_count] = decisions.size
          payload[:decision_actions] = decisions.map { |decision| decision.action.to_s }
          decisions
        end
      end

      def apply(decision, scope)
        case decision.action
        when :add
          raise Engram::Error, "cannot move memory across scopes" unless decision.candidate.scope == scope

          decision if persistence.add(decision.candidate, scope: scope)
        when :update
          if decision.target_id && persistence.update(scope: scope, id: decision.target_id, record: decision.candidate)
            decision
          end
        when :forget
          if decision.target_id
            deleted = @store.delete(scope: scope, id: decision.target_id)
            decision if deleted && deleted != 0
          end
        when :noop
          nil
        end
      end

      def persistence
        @persistence ||= Persistence.new(store: @store, embedder: @embedder)
      end
    end
  end
end
