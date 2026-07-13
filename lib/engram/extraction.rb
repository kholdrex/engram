# frozen_string_literal: true

module Engram
  # An immutable extractor result that carries a candidate Record and its source provenance.
  # Converting it creates a new record and leaves the caller-owned record and metadata untouched.
  class Extraction
    attr_reader :record, :provenance

    def initialize(record:, provenance:)
      raise ArgumentError, "record must be an Engram::Record" unless record.is_a?(Engram::Record)
      raise ArgumentError, "provenance must be an Engram::Provenance" unless provenance.is_a?(Engram::Provenance)

      @record = record
      @provenance = provenance
      freeze
    end

    def to_record
      record.with(metadata: Engram::Provenance.attach(record.metadata, provenance))
    end
  end
end
