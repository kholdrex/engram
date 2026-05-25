# frozen_string_literal: true

module Engram
  module Ports
    # Contract for reconciling candidate facts against existing memories: decide
    # ADD / UPDATE / FORGET / NOOP per candidate. This is what separates "memory" from a
    # dumb pile of embeddings.
    # Implementations: Consolidators::HeuristicConsolidator, Consolidators::LLMConsolidator.
    module Consolidator
      # Given Array<Record> candidates and a scope, return Array<Decision> (one per
      # candidate that should result in an action).
      def reconcile_all(candidates:, scope:)
        raise NotImplementedError, "#{self.class} must implement #reconcile_all"
      end
    end
  end
end
