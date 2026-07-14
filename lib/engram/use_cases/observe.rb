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
      CANDIDATE_STATE_ATTRIBUTES = %i[
        id content scope embedding kind importance metadata created_at last_accessed_at
      ].freeze

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
            unless @processed_turns.completed?(scope: scope, key: idempotency_key)
              # A live, incomplete lease is retryable, not a completed duplicate.
              raise Engram::ObservationInProgressError,
                "observation for this turn is claimed but not completed; retry after the claim lease expires"
            end

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
            operations = preflight(decisions, candidates, scope)
            applied_decisions = operations.filter_map { |operation| apply(operation, scope) }
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
          candidates = normalize_extractions(@extractor.extract(messages: messages, scope: scope))
          payload[:candidate_count] = candidates.size
          candidates
        end
      end

      def normalize_extractions(results)
        unless results.is_a?(Array)
          raise Engram::Error, "extractor must return an Array containing only Engram::Record or Engram::Extraction values"
        end

        results.map do |result|
          case result
          when Engram::Record then result
          when Engram::Extraction then result.to_record
          else
            raise Engram::Error, "extractor must return an Array containing only Engram::Record or Engram::Extraction values"
          end
        end
      end

      def consolidate(candidates:, scope:)
        payload = Engram::Instrumentation.payload(scope: scope, store: @store, candidate_count: candidates.size)
        Engram::Instrumentation.instrument("consolidate", payload) do
          candidate_snapshots = candidates.map { |candidate| [candidate, snapshot_candidate(candidate)] }
          raw_decisions = @consolidator.reconcile_all(candidates: candidates, scope: scope)
          decisions = canonicalize_decisions(raw_decisions)
          verify_candidates_unchanged!(candidate_snapshots)

          payload[:decision_count] = decisions.size
          decisions
        end
      end

      def canonicalize_decisions(raw_decisions)
        unless raw_decisions.is_a?(Array)
          raise Engram::Error, "consolidator must return an Array of Engram::Decision values"
        end

        raw_decisions.map do |raw_decision|
          unless raw_decision.is_a?(Engram::Decision)
            raise Engram::Error, "consolidator must return an Array of Engram::Decision values"
          end

          action = raw_decision.action
          candidate = raw_decision.candidate
          target_id = raw_decision.target_id
          reason = raw_decision.reason
          unless Engram::Decision::ACTIONS.include?(action)
            raise Engram::Error, "unsupported decision action #{action.inspect}"
          end

          Engram::Decision.new(action: action, candidate: candidate, target_id: target_id, reason: reason)
        end
      end

      def snapshot_candidate(candidate)
        CANDIDATE_STATE_ATTRIBUTES.to_h do |attribute|
          [attribute, deep_copy_candidate_value(candidate.public_send(attribute))]
        end
      end

      def deep_copy_candidate_value(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, nested_value), copy|
            copy[deep_copy_candidate_value(key)] = deep_copy_candidate_value(nested_value)
          end
        when Array
          value.map { |element| deep_copy_candidate_value(element) }
        when String
          value.dup
        else
          value
        end
      end

      def verify_candidates_unchanged!(candidate_snapshots)
        changed = candidate_snapshots.any? do |candidate, snapshot|
          CANDIDATE_STATE_ATTRIBUTES.any? do |attribute|
            candidate.public_send(attribute) != snapshot.fetch(attribute)
          end
        end
        raise Engram::Error, "consolidators must not mutate candidates" if changed
      end

      def preflight(decisions, candidates, scope)
        candidate_budget = Hash.new(0).compare_by_identity
        candidates.each { |candidate| candidate_budget[candidate] += 1 }
        decision_counts = Hash.new(0).compare_by_identity

        decisions.each do |decision|
          unless decision.is_a?(Engram::Decision)
            raise Engram::Error, "consolidator must return an Array of Engram::Decision values"
          end
          unless Engram::Decision::ACTIONS.include?(decision.action)
            raise Engram::Error, "unsupported decision action #{decision.action.inspect}"
          end
          unless decision.candidate.is_a?(Engram::Record)
            message = if decision.action == :forget
              "forget decision candidate must be an Engram::Record"
            else
              "decision candidate must be an Engram::Record"
            end
            raise Engram::Error, message
          end
          unless candidate_budget.key?(decision.candidate)
            raise Engram::Error, "decision must reference the actual candidate supplied to the consolidator"
          end
          decision_counts[decision.candidate] += 1
          if decision_counts[decision.candidate] > candidate_budget.fetch(decision.candidate)
            raise Engram::Error,
              "consolidator must return no more than one decision per candidate occurrence; " \
              "multiple decisions reference the same candidate"
          end
          raise Engram::Error, "cannot move memory across scopes" unless decision.candidate.scope == scope

          if %i[update forget].include?(decision.action) && !decision.target_id
            raise Engram::Error, "#{decision.action} decision requires a target_id"
          end

          Engram::Provenance.extract_for_persistence(decision.candidate.metadata)
        end

        preflight_destructive_targets!(decisions, scope)
        decisions.map { |decision| prepare_operation(decision, scope) }
      end

      def preflight_destructive_targets!(decisions, scope)
        target_ids = decisions.filter_map do |decision|
          decision.target_id if %i[update forget].include?(decision.action)
        end
        return if target_ids.empty?

        duplicate_id = target_ids.tally.find { |_, count| count > 1 }&.first
        if duplicate_id
          raise Engram::Error, "multiple decisions target memory #{duplicate_id.inspect}"
        end

        existing_ids = scoped_existing_ids(scope, target_ids)
        existing_id_lookup = existing_ids.each_with_object({}) { |id, lookup| lookup[id] = true }
        missing_id = target_ids.find { |target_id| !existing_id_lookup[target_id] }
        if missing_id
          raise Engram::Error, "no memory with id #{missing_id.inspect} in scope #{scope.inspect}"
        end
      end

      def scoped_existing_ids(scope, target_ids)
        if @store.respond_to?(:existing_ids)
          begin
            return Array(@store.existing_ids(scope: scope, ids: target_ids))
          rescue NotImplementedError
            # Optional capability: legacy adapters may inherit the default stub.
          end
        end

        @store.all(scope: scope).map(&:id)
      end

      def prepare_operation(decision, scope)
        prepared = case decision.action
        when :add
          persistence.prepare(decision.candidate)
        when :update
          persistence.prepare(decision.candidate) if decision.target_id
        when :forget
          persistence.allowed?(decision.candidate) if decision.target_id
        end

        if %i[add update].include?(decision.action) && prepared && prepared.scope != scope
          raise Engram::Error, "cannot move memory across scopes"
        end

        [decision, prepared]
      end

      def apply(operation, scope)
        decision, prepared = operation
        case decision.action
        when :add
          decision if prepared && persistence.add_prepared(prepared, scope: scope)
        when :update
          if decision.target_id && prepared &&
              persistence.update_prepared(scope: scope, id: decision.target_id, record: prepared)
            decision
          end
        when :forget
          if decision.target_id && prepared
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
