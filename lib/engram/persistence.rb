# frozen_string_literal: true

module Engram
  # Applies persistence hooks and policy consistently before writing records.
  class Persistence
    RECORD_METADATA_READER = Engram::Record.instance_method(:metadata)

    def initialize(store:, embedder:, before_persist: Engram.config.before_persist,
      persistence_policy: Engram.config.persistence_policy)
      @store = store
      @embedder = embedder
      @before_persist = before_persist
      @persistence_policy = persistence_policy
    end

    def add(record, scope: record.scope)
      add_prepared(prepare(record), scope: scope)
    end

    def update(scope:, id:, record:)
      update_prepared(scope: scope, id: id, record: prepare(record))
    end

    # Persists a record already returned by #prepare. These split-phase methods let
    # orchestrators prepare a complete batch before beginning store mutations.
    def add_prepared(record, scope: record&.scope)
      return unless record

      validate_provenance!(record)
      unless Engram::Internal::Scope.record_matches?(record, scope)
        raise Engram::Error, "cannot move memory across scopes"
      end

      @store.add(record)
    end

    def update_prepared(scope:, id:, record:)
      return unless record

      validate_provenance!(record)
      unless Engram::Internal::Scope.record_matches?(record, scope)
        raise Engram::Error, "cannot move memory across scopes"
      end

      @store.update(scope: scope, id: id, record: record)
    end

    # Applies all write transformations without mutating the store. Input is validated
    # before callbacks can remove or replace provenance, and final output is validated too.
    def prepare(record)
      original_provenance = validate_provenance!(record)
      original_content = record.content
      record = @before_persist.call(record) if @before_persist
      if record
        transformed_provenance = validate_provenance!(record)
        validate_provenance_trust!(original_provenance, transformed_provenance) if @before_persist
      end
      record = @persistence_policy.call(record) if record && @persistence_policy
      validate_provenance!(record) if record
      if record && record.content != original_content
        record = record.with(embedding: @embedder.embed(record.content))
      end
      record = Engram::EmbeddingMetadata.attach(record, embedder: @embedder) if record
      validate_provenance!(record) if record
      record
    end

    # Authorizes a destructive decision without applying write transformations or content
    # filtering. Policies may opt into this separate contract with #allow_destructive?.
    # Malformed provenance always fails closed.
    def allowed?(record)
      validate_provenance!(record)
      return true unless @persistence_policy&.respond_to?(:allow_destructive?)

      authorization = @persistence_policy.allow_destructive?(record)
      unless authorization.equal?(true) || authorization.equal?(false)
        raise Engram::Error, "persistence policy allow_destructive? must return true or false"
      end
      validate_provenance!(record)

      authorization
    end

    private

    def validate_provenance!(record)
      metadata = RECORD_METADATA_READER.bind_call(record)
      Engram::Provenance.canonical_integrity_representation_for_persistence(metadata)
    rescue TypeError
      raise Engram::Error, "persistence requires an Engram::Record"
    end

    def validate_provenance_trust!(original, transformed)
      return if original == transformed

      raise Engram::Error, "before_persist cannot change provenance trust"
    end
  end
end
