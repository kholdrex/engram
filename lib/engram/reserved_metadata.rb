# frozen_string_literal: true

module Engram
  # Collision-preserving operations for schemas sharing Engram's metadata namespace.
  module ReservedMetadata
    KEY = "_engram"

    module_function

    def attach(metadata, schema_key, value, namespace_description: "metadata")
      metadata = (metadata || {}).dup
      reserved_values = [metadata.delete(KEY), metadata.delete(:_engram)].compact
      unless reserved_values.all? { |reserved| reserved.is_a?(Hash) }
        raise Engram::Error, "metadata key #{KEY.inspect} is reserved for Engram #{namespace_description}"
      end

      reserved = reserved_values.reduce({}) do |merged, reserved_value|
        siblings = reserved_value.reject { |key, _nested| key.to_s == schema_key }
        merge(merged, normalize(siblings))
      end
      metadata.merge(KEY => reserved.merge(schema_key => normalize(value)))
    end

    def normalize(value, path = [])
      return value.map { |nested| normalize(nested, path) } if value.is_a?(Array)
      return value unless value.is_a?(Hash)

      value.each_with_object({}) do |(key, nested), normalized|
        string_key = key.to_s
        normalized_value = normalize(nested, path + [string_key])
        normalized[string_key] = if normalized.key?(string_key)
          merge_value(normalized[string_key], normalized_value, path + [string_key])
        else
          normalized_value
        end
      end
    end

    def merge(left, right, path = [])
      right.each_with_object(left.dup) do |(key, value), merged|
        merged[key] = merged.key?(key) ? merge_value(merged[key], value, path + [key]) : value
      end
    end

    def merge_value(left, right, path)
      return merge(left, right, path) if left.is_a?(Hash) && right.is_a?(Hash)
      return left if left == right

      raise Engram::Error, "conflicting reserved metadata at #{path.join(".")}"
    end
  end
end
