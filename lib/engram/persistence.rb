# frozen_string_literal: true

module Engram
  # Applies persistence hooks and policy consistently before writing records.
  class Persistence
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
      raise Engram::Error, "cannot move memory across scopes" unless record.scope == scope

      @store.add(record)
    end

    def update_prepared(scope:, id:, record:)
      return unless record

      validate_provenance!(record)
      raise Engram::Error, "cannot move memory across scopes" unless record.scope == scope

      @store.update(scope: scope, id: id, record: record)
    end

    # Applies all write transformations without mutating the store. Input is validated
    # before callbacks can remove or replace provenance, and final output is validated too.
    def prepare(record)
      validate_provenance!(record)
      original_content = record.content
      record = @before_persist.call(record) if @before_persist
      validate_provenance!(record) if record
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
      Engram::Provenance.extract_for_persistence(record.metadata)
    end
  end
end
