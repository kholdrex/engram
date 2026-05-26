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

    def add(record)
      record = prepare(record)
      @store.add(record) if record
    end

    def update(id:, record:)
      record = prepare(record)
      @store.update(id: id, record: record) if record
    end

    private

    def prepare(record)
      original_content = record.content
      record = @before_persist.call(record) if @before_persist
      record = @persistence_policy.call(record) if record && @persistence_policy
      record = record.with(embedding: @embedder.embed(record.content)) if record && record.content != original_content
      record
    end
  end
end
