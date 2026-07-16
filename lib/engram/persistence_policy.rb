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

    def initialize(denylist_patterns: [], allow_ungrounded: false)
      @denylist_patterns = denylist_patterns
      @allow_ungrounded = BasicObject.instance_method(:equal?).bind_call(allow_ungrounded, true)
    end

    def call(record)
      provenance = Engram::Provenance.extract_for_persistence(record.metadata)
      return nil if provenance&.ungrounded? && !@allow_ungrounded
      return nil if reject?(record.content)

      redact(record)
    end

    # Destructive authorization is deliberately independent from write-content filtering and
    # redaction. Provenance trust still applies, but secret/transient content can always be removed.
    def allow_destructive?(record)
      provenance = Engram::Provenance.extract_for_persistence(record.metadata)
      !provenance&.ungrounded? || @allow_ungrounded
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
