# frozen_string_literal: true

module Engram
  module Ports
    # Contract for structured LLM calls used by extraction and consolidation.
    # Implementations: Adapters::RubyLLMCompletion (real), Adapters::FakeCompletion (tests).
    module Completion
      # Run a completion and return parsed structured data conforming to `schema`
      # (a JSON-schema-ish Hash). `system` and `user` are prompt strings.
      def complete(system:, user:, schema:)
        raise NotImplementedError, "#{self.class} must implement #complete"
      end
    end
  end
end
