# frozen_string_literal: true

module Engram
  module UseCases
    # Look up which memories in a scope reference a given host source.
    #
    # Returns the records whose understood provenance lists a source matching both
    # `source_id` and `source_type` exactly, with no trimming or normalization.
    # Reads stay tolerant: legacy, malformed, and future-schema
    # provenance simply do not match. Source IDs are references, not authorization
    # boundaries, so callers still bound the lookup to a `scope`.
    class SourceImpact
      def initialize(store:)
        @store = store
      end

      # Returns the Array<Record> in `scope` referencing the exact source. Result
      # order follows the store's #all enumeration and is not otherwise guaranteed.
      def call(scope:, source_id:, source_type:)
        source_id = require_string!("source_id", source_id)
        source_type = require_string!("source_type", source_type)

        @store.all(scope: scope).select do |record|
          provenance = record.provenance
          provenance&.sources&.any? do |source|
            source.source_id == source_id && source.source_type == source_type
          end
        end
      end

      private

      def require_string!(name, value)
        unless value.is_a?(String) && !value.strip.empty?
          raise ArgumentError, "#{name} must be a non-empty String"
        end

        value
      end
    end
  end
end
