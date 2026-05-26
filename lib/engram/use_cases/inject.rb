# frozen_string_literal: true

require "cgi"

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

        block = memories.map { |memory| render_memory(memory) }.join("\n")
        "#{prompt}\n\n#{@header}:\n<engram-memories>\n#{block}\n</engram-memories>"
      end

      private

      def render_memory(memory)
        kind = CGI.escapeHTML((memory.kind || :fact).to_s)
        content = CGI.escapeHTML(memory.content.to_s)

        %(<engram-memory kind="#{kind}">#{content}</engram-memory>)
      end
    end
  end
end
