# frozen_string_literal: true

module Engram
  module UseCases
    # Scoped read/merge/write correction. Concurrent writers require host coordination.
    class Update
      def initialize(store:, embedder:)
        @store = store
        @embedder = embedder
      end

      def call(scope:, id:, attributes:)
        attributes = validate_attributes!(id, attributes)
        payload = Engram::Instrumentation.payload(scope: scope, store: @store,
          fields: attributes.keys.map(&:to_s), content_changed: false, reembedded: false)
        Engram::Instrumentation.instrument("update", payload) do
          original = find(scope, id)
          unless original && Engram::Internal::Scope.record_matches?(original, scope)
            payload[:outcome] = "missing"
            raise Engram::MemoryNotFoundError, "no memory in this scope"
          end

          # Validate before any edit can remove inherited evidence.
          Engram::Provenance.canonical_payload_for_persistence(original.metadata)
          original = detach(plain_times(original))
          original = original.with(metadata: Engram::Provenance.canonical_metadata_for_persistence(original.metadata))
          persistence = Engram::Persistence.new(store: @store, embedder: @embedder)
          unless persistence.allowed?(detach(original))
            payload[:outcome] = "rejected"
            next nil
          end

          candidate = merge(original, attributes)
          candidate = invalidate_provenance(candidate, original)
          payload[:content_changed] = candidate.content != original.content
          evidence = provenance(candidate)
          candidate = persistence.transform(candidate) do |transformed|
            validate_transformation!(transformed, original, scope)
            unless provenance(transformed) == evidence
              raise Engram::Error, "update transformations cannot change provenance trust"
            end
            transformed = invalidate_provenance(transformed, original)
            evidence = provenance(transformed)
            payload[:content_changed] = transformed.content != original.content
            transformed
          end
          unless candidate
            payload[:outcome] = "rejected"
            next nil
          end

          payload[:content_changed] = candidate.content != original.content
          candidate = replace_reserved_field(candidate, "embedding")
          if payload[:content_changed] || original.embedding.nil?
            candidate = candidate.with(embedding: @embedder.embed(candidate.content))
            payload[:reembedded] = true
            candidate = Engram::EmbeddingMetadata.attach(candidate, embedder: @embedder)
          else
            candidate = replace_reserved_field(candidate, "embedding", source: original)
              .with(embedding: original.embedding)
          end
          candidate = candidate.with(created_at: original.created_at, last_accessed_at: original.last_accessed_at)
          stored = persistence.update_prepared(scope: scope, id: id, record: candidate)
          payload[:outcome] = "updated"
          stored
        end
      end

      private

      def validate_attributes!(id, attributes)
        valid_id = id.instance_of?(Integer) || (id.instance_of?(String) && id.valid_encoding? && !id.strip.empty?)
        raise ArgumentError, "id must be an Integer or a non-empty String" unless valid_id
        raise ArgumentError, "at least one attribute must be supplied" if attributes.empty?

        attributes = attributes.dup
        attributes.each do |field, value|
          valid = case field
          when :content
            value.is_a?(String) && value.valid_encoding? && !value.strip.empty?
          when :kind
            attributes[field] = Engram::MemoryKind.normalize(value)
            true
          when :importance
            (value.is_a?(Integer) || value.is_a?(Float)) && value.finite?
          when :metadata
            value.is_a?(Hash) && !reserved_metadata?(value)
          when :expires_at
            value.nil? || value.is_a?(Time)
          else
            false
          end
          raise ArgumentError, "invalid #{field}" unless valid
        end
        attributes
      end

      def reserved_metadata?(metadata)
        Engram::Internal::CoreHash.each_pair(metadata) do |key, _|
          return true if key.equal?(:_engram)
          return true if key.is_a?(String) && String.instance_method(:==).bind_call(key, "_engram")
        end
        false
      end

      def find(scope, id)
        if @store.respond_to?(:find)
          begin
            return @store.find(scope: scope, id: id)
          rescue NotImplementedError
            # Optional capability: legacy adapters may inherit the default stub.
          end
        end
        @store.all(scope: scope).find { |record| record.id == id }
      end

      def detach(record)
        Engram::Internal::CandidateIntegrity.new.detach(record)
      rescue Engram::Internal::CandidateIntegrity::Error => error
        raise Engram::Error, error.message
      end

      # Rails stores return ActiveSupport::TimeWithZone; candidates accept only plain Time.
      def plain_times(record)
        record.with(
          created_at: plain_time(record.created_at),
          last_accessed_at: plain_time(record.last_accessed_at),
          expires_at: plain_time(record.expires_at)
        )
      end

      def plain_time(value)
        (value.nil? || value.instance_of?(Time)) ? value : Time.at(value.to_r).utc
      end

      def merge(original, attributes)
        if attributes.key?(:metadata)
          metadata = Hash.instance_method(:transform_values).bind_call(attributes[:metadata]) { |value| value }
          ["_engram", :_engram].each do |key|
            metadata[key] = original.metadata[key] if original.metadata.key?(key)
          end
          attributes = attributes.merge(metadata: metadata)
        end
        detach(original.with(**attributes))
      end

      def provenance(record)
        Engram::Provenance.canonical_integrity_representation_for_persistence(record.metadata)
      end

      def invalidate_provenance(record, original)
        return record if record.content == original.content

        replace_reserved_field(record, "provenance")
      end

      # Keep unrelated reserved siblings and preserve the stored embedding schema
      # exactly when reusing its vector, including legacy symbol-key aliases.
      def replace_reserved_field(record, field, source: nil)
        metadata = record.metadata.dup
        ["_engram", :_engram].each do |key|
          reserved = metadata[key]&.dup || {}
          reserved.delete(field)
          reserved.delete(field.to_sym)
          inherited = source&.metadata&.fetch(key, {}) || {}
          [field, field.to_sym].each do |alias_key|
            reserved[alias_key] = inherited[alias_key] if inherited.key?(alias_key)
          end
          metadata[key] = reserved if metadata.key?(key) || !reserved.empty?
        end
        record.with(metadata: metadata)
      end

      def validate_transformation!(record, original, scope)
        unless Engram::Internal::Scope.record_matches?(record, scope) && record.id == original.id
          raise Engram::Error, "update transformations cannot change memory identity or scope"
        end
        validate_attributes!(record.id,
          content: record.content, kind: record.kind, importance: record.importance, expires_at: record.expires_at)
      rescue ArgumentError => error
        raise Engram::Error, error.message
      end
    end
  end
end
