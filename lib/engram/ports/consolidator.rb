# frozen_string_literal: true

module Engram
  module Ports
    # Contract for reconciling candidate facts against existing memories: decide
    # ADD / UPDATE / FORGET / NOOP per candidate. This is what separates "memory" from a
    # dumb pile of embeddings.
    # Implementations: Consolidators::HeuristicConsolidator, Consolidators::LLMConsolidator.
    module Consolidator
      # Given Array<Record> candidates and a scope, return Array<Decision> (at most one
      # per candidate occurrence, including NOOP decisions). Each decision must reference
      # the actual candidate instance from this array, not a copy or replacement. When the
      # same instance occurs multiple times, it may have no more decisions than occurrences.
      # Candidates are read-only reconciliation inputs: implementations must not mutate
      # their state, including nested metadata or embedding values. Decision target IDs
      # must be plain String or Integer values without singleton behavior or custom state.
      def reconcile_all(candidates:, scope:)
        raise NotImplementedError, "#{self.class} must implement #reconcile_all"
      end
    end
  end
end
