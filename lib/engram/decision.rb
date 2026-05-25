# frozen_string_literal: true

module Engram
  # The outcome of consolidating one candidate fact against existing memory.
  #
  #   action     - :add | :update | :forget | :noop
  #   candidate  - the Record produced by extraction
  #   target_id  - id of the existing memory to update/forget (nil for add/noop)
  #   reason     - optional human-readable rationale (useful for audit/eval)
  class Decision
    ACTIONS = %i[add update forget noop].freeze

    attr_reader :action, :candidate, :target_id, :reason

    def initialize(action:, candidate:, target_id: nil, reason: nil)
      action = action.to_sym
      unless ACTIONS.include?(action)
        raise ArgumentError, "unknown action #{action.inspect}; expected one of #{ACTIONS.inspect}"
      end

      @action = action
      @candidate = candidate
      @target_id = target_id
      @reason = reason
    end
  end
end
