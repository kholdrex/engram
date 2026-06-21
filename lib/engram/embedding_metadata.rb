# frozen_string_literal: true

require "digest"

module Engram
  # Helpers for storing and validating embedding provenance under Engram's
  # reserved metadata namespace.
  module EmbeddingMetadata
    RESERVED_KEY = "_engram"
    EMBEDDING_KEY = "embedding"

    module_function

    def build(adapter:, dimensions:, model: nil, provider: nil)
      data = {
        "adapter" => adapter.to_s,
        "dimensions" => dimensions
      }
      data["provider"] = provider.to_s if provider
      data["model"] = model.to_s if model
      data["fingerprint"] = fingerprint(data)
      data
    end

    def for_embedder(embedder, embedding: nil)
      return nil unless embedder.respond_to?(:embedding_metadata)

      metadata = stringify_keys(embedder.embedding_metadata || {})
      return nil if metadata.empty?

      dimensions = embedding.respond_to?(:length) ? embedding.length : metadata["dimensions"]
      metadata = metadata.merge("dimensions" => dimensions) if dimensions
      metadata["fingerprint"] = fingerprint(metadata)
      metadata
    end

    def attach(record, embedder: nil, embedding_metadata: nil)
      metadata = stringify_keys(embedding_metadata || for_embedder(embedder, embedding: record.embedding)) || {}
      return record if metadata.empty?

      record.with(metadata: merge(record.metadata, metadata))
    end

    def extract(metadata)
      metadata = stringify_keys(metadata || {})
      stringify_keys(metadata.dig(RESERVED_KEY, EMBEDDING_KEY) || {})
    end

    def merge(metadata, embedding_metadata)
      metadata = (metadata || {}).dup
      reserved = metadata.delete(RESERVED_KEY) || metadata.delete(:_engram) || {}
      unless reserved.is_a?(Hash)
        raise Engram::Error,
          "metadata key #{RESERVED_KEY.inspect} is reserved for Engram embedding metadata"
      end

      reserved = stringify_keys(reserved)
      unexpected_reserved_keys = reserved.keys - [EMBEDDING_KEY]
      unless unexpected_reserved_keys.empty?
        raise Engram::Error,
          "metadata key #{RESERVED_KEY.inspect} is reserved for Engram embedding metadata"
      end

      metadata.merge(
        RESERVED_KEY => reserved.merge(EMBEDDING_KEY => stringify_keys(embedding_metadata || {}))
      )
    end

    def search(store, embedding:, embedding_metadata:, scope:, limit:, kinds: nil)
      store.search(
        embedding: embedding,
        embedding_metadata: embedding_metadata,
        scope: scope,
        limit: limit,
        kinds: kinds
      )
    rescue ArgumentError => error
      raise unless unknown_embedding_metadata_keyword?(error)

      store.search(embedding: embedding, scope: scope, limit: limit, kinds: kinds)
    end

    def validate_query!(embedding, embedding_metadata)
      metadata = stringify_keys(embedding_metadata || {})
      return if metadata.empty?

      expected = metadata["dimensions"]
      return unless expected && embedding.respond_to?(:length) && embedding.length != expected.to_i

      raise Engram::Error,
        "embedding dimension mismatch: query vector has #{embedding.length} dimensions, metadata declares #{expected}"
    end

    def validate_record!(record, query_embedding, query_metadata)
      if query_embedding.respond_to?(:length) && record.embedding.respond_to?(:length) &&
          query_embedding.length != record.embedding.length
        raise Engram::Error,
          "embedding dimension mismatch: query vector has #{query_embedding.length} dimensions, " \
          "record #{record.id.inspect} has #{record.embedding.length}"
      end

      stored = extract(record.metadata)
      return if stored.empty?

      stored_dimensions = stored["dimensions"]
      if stored_dimensions && record.embedding.respond_to?(:length) && record.embedding.length != stored_dimensions.to_i
        raise Engram::Error,
          "embedding metadata mismatch: record #{record.id.inspect} has #{record.embedding.length} dimensions, " \
          "metadata declares #{stored_dimensions}"
      end

      query_metadata = stringify_keys(query_metadata || {})
      return if query_metadata.empty?

      conflicting_key = %w[fingerprint adapter provider model dimensions].find do |key|
        stored.key?(key) && query_metadata.key?(key) && stored[key].to_s != query_metadata[key].to_s
      end
      return unless conflicting_key

      raise Engram::Error,
        "embedding metadata mismatch for record #{record.id.inspect}: #{conflicting_key} " \
        "#{stored[conflicting_key].inspect} does not match query #{query_metadata[conflicting_key].inspect}"
    end

    def fingerprint(metadata)
      relevant = stringify_keys(metadata).values_at("adapter", "provider", "model", "dimensions")
      Digest::SHA256.hexdigest(relevant.map { |value| value.nil? ? "" : value.to_s }.join("\0"))
    end

    def stringify_keys(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, nested), out|
          out[key.to_s] = stringify_keys(nested)
        end
      else
        value
      end
    end

    def unknown_embedding_metadata_keyword?(error)
      error.message.include?("unknown keyword: :embedding_metadata") ||
        error.message.include?("unknown keyword: \"embedding_metadata\"")
    end
  end
end
