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
      record = prepare(record)
      if record && record.scope != scope
        raise Engram::Error, "cannot move memory across scopes"
      end
      @store.add(record) if record
    end

    def update(scope:, id:, record:)
      record = prepare(record)
      @store.update(scope: scope, id: id, record: record) if record
    end

    # Applies policy to a candidate that authorizes a destructive decision. Malformed
    # provenance raises Engram::Error rather than authorizing the decision. Hooks and embedding
    # preparation are intentionally reserved for records that will be written.
    def allowed?(record)
      !@persistence_policy || !!@persistence_policy.call(record)
    end

    private

    def prepare(record)
      original_content = record.content
      record = @before_persist.call(record) if @before_persist
      record = @persistence_policy.call(record) if record && @persistence_policy
      if record && record.content != original_content
        record = record.with(embedding: @embedder.embed(record.content))
      end
      record ? Engram::EmbeddingMetadata.attach(record, embedder: @embedder) : nil
    end
  end
end
