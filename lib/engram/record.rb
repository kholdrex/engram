# frozen_string_literal: true

module Engram
  # A single unit of memory.
  #
  # `id` is assigned by the store on persistence (nil until then); consolidation uses it
  # to target UPDATE/FORGET. `scope` namespaces memories to an owner (e.g. "user:42").
  # `kind` is a memory type (semantic / episodic / preference).
  class Record
    attr_accessor :id
    attr_reader :content, :embedding, :scope, :kind, :importance, :metadata,
      :created_at, :last_accessed_at

    def initialize(content:, scope:, id: nil, embedding: nil, kind: :semantic,
      importance: 1.0, metadata: {}, created_at: nil, last_accessed_at: nil)
      @id = id
      @content = content
      @scope = scope
      @embedding = embedding
      @kind = kind
      @importance = importance
      @metadata = metadata
      @created_at = created_at || Time.now
      @last_accessed_at = last_accessed_at
    end

    def to_h
      {
        id: id, content: content, scope: scope, embedding: embedding, kind: kind,
        importance: importance, metadata: metadata,
        created_at: created_at, last_accessed_at: last_accessed_at
      }
    end
  end
end
