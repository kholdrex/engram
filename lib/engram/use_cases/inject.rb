# frozen_string_literal: true

module Engram
  module UseCases
    # Render recalled memories into a prompt as a clearly delimited block.
    class Inject
      DEFAULT_HEADER = "# What you remember about the user"

      def initialize(header: DEFAULT_HEADER)
        @header = header
      end

      # Returns a new prompt string. If there are no memories, the prompt is unchanged.
      def call(prompt:, memories:)
        return prompt if memories.nil? || memories.empty?

        block = memories.map { |m| "- #{m.content}" }.join("\n")
        "#{prompt}\n\n#{@header}:\n#{block}"
      end
    end
  end
end
