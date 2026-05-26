# frozen_string_literal: true

module Engram
  # Canonical memory categories used by extraction, recall, and policy.
  module MemoryKind
    VALID = %i[fact preference instruction episodic].freeze
    LEGACY_ALIASES = {semantic: :fact}.freeze

    module_function

    def normalize(kind)
      normalized = kind.to_s.strip.downcase.to_sym
      normalized = LEGACY_ALIASES.fetch(normalized, normalized)
      return normalized if VALID.include?(normalized)

      raise ArgumentError, "unknown memory kind #{kind.inspect}; expected one of #{VALID.join(", ")}"
    end
  end
end
