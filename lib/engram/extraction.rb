# frozen_string_literal: true

module Engram
  # An immutable extractor result that carries a candidate Record and its source provenance.
  # Converting it creates a new record and leaves the caller-owned record and metadata untouched.
  class Extraction
    attr_reader :record, :provenance

    def initialize(record:, provenance:)
      is_record = Object.instance_method(:is_a?).bind_call(record, Engram::Record)
      raise ArgumentError, "record must be an Engram::Record" unless is_record

      is_provenance = Object.instance_method(:is_a?).bind_call(provenance, Engram::Provenance)
      raise ArgumentError, "provenance must be an Engram::Provenance" unless is_provenance

      @record = record
      @provenance = provenance
      freeze
    end

    def to_record
      exact_record = Object.instance_method(:instance_of?).bind_call(record, Engram::Record)
      detached = Engram::Internal::CandidateIntegrity.new.detach(record)
      source = exact_record ? record : detached
      attributes = Engram::Record::STATE_READERS.to_h do |attribute|
        [attribute, Engram::Record.instance_method(attribute).bind_call(source)]
      end
      attributes[:metadata] = Engram::Provenance.attach(attributes.fetch(:metadata), provenance)
      Engram::Record.new(**attributes)
    end
  end
end
