# frozen_string_literal: true

module Engram
  # Default gate applied before memories are persisted. It keeps obvious secrets and
  # transient task-progress updates out of durable memory, and can redact caller-supplied
  # denylist patterns before storage.
  class PersistencePolicy
    SECRET_PATTERNS = [
      /\b(?:api[_ -]?key|token|secret|password)\b\s*(?:is|=|:)\s+(?=\S*[0-9_-])\S{8,}/i,
      /\bsk-[A-Za-z0-9_-]{6,}\b/,
      /\b(?:ghp|github_pat)_[A-Za-z0-9_]{10,}\b/
    ].freeze

    TRANSIENT_PATTERNS = [
      /\b(?:fixed|resolved|done|completed|finished)\b.*\b(?:today|now|this session)\b/i,
      /\b(?:today|now|this session)\b.*\b(?:fixed|resolved|done|completed|finished)\b/i
    ].freeze

    def initialize(denylist_patterns: [])
      @denylist_patterns = denylist_patterns
    end

    def call(record)
      return nil if reject?(record.content)

      redact(record)
    end

    private

    def reject?(content)
      SECRET_PATTERNS.any? { |pattern| content.match?(pattern) } ||
        TRANSIENT_PATTERNS.any? { |pattern| content.match?(pattern) }
    end

    def redact(record)
      redacted = @denylist_patterns.reduce(record.content) do |content, pattern|
        content.gsub(pattern, "[REDACTED]")
      end
      return record if redacted == record.content

      record.with(content: redacted)
    end
  end
end
