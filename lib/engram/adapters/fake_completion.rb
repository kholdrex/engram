# frozen_string_literal: true

module Engram
  module Adapters
    # Deterministic Completion for tests. Returns queued responses (already-parsed Hashes)
    # in order, and records every call so specs can assert on the prompts/schemas sent.
    class FakeCompletion
      include Ports::Completion

      attr_reader :calls

      def initialize(responses: [])
        @responses = responses.dup
        @calls = []
      end

      def enqueue(response)
        @responses << response
        self
      end

      def complete(system:, user:, schema:)
        @calls << {system: system, user: user, schema: schema}
        if @responses.empty?
          raise Engram::Error, "FakeCompletion: no scripted response left (call ##{@calls.size})"
        end

        @responses.shift
      end
    end
  end
end
