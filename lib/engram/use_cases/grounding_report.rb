# frozen_string_literal: true

module Engram
  module UseCases
    # Count records in a scope by their weakest understood source alignment.
    class GroundingReport
      ALIGNMENTS = %i[exact normalized inferred ungrounded].freeze
      private_constant :ALIGNMENTS

      def initialize(store:)
        @store = store
      end

      def call(scope:)
        counts = {
          exact: 0,
          normalized: 0,
          inferred: 0,
          ungrounded: 0,
          unattributed: 0,
          total: 0
        }

        @store.all(scope: scope).each do |record|
          provenance = record.provenance
          alignment = provenance && weakest_alignment(provenance)
          counts[alignment || :unattributed] += 1
          counts[:total] += 1
        end

        counts.freeze
      end

      private

      def weakest_alignment(provenance)
        provenance.sources.map(&:alignment).max_by { |alignment| ALIGNMENTS.index(alignment) }
      end
    end
  end
end
