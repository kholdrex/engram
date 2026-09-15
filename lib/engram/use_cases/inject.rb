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

      def self.validate_max_bytes!(value)
        return if value.nil? || (value.is_a?(Integer) && value >= 0)

        raise ArgumentError, "max_bytes must be a non-negative integer, or nil"
      end

      # The budget includes the header, delimiters, escaping, and separators, but
      # excludes the original prompt. Skip whole memories that do not fit.
      def call(prompt:, memories:, max_bytes: nil)
        self.class.validate_max_bytes!(max_bytes)
        payload = {memory_count: memories&.size.to_i, injected_count: 0,
                   skipped_count: memories&.size.to_i, injected_bytes: 0, max_bytes: max_bytes}.compact
        Engram::Instrumentation.instrument("inject", payload) do
          next prompt if memories.nil? || memories.empty? || max_bytes == 0

          prefix = "\n\n#{@header}:\n<engram-memories>\n"
          suffix = "\n</engram-memories>"
          bytes = prefix.bytesize + suffix.bytesize
          lines = []
          now = Time.now
          memories.each do |memory|
            next if memory.expired?(at: now)

            line = render_memory(memory)
            added_bytes = line.bytesize + (lines.empty? ? 0 : 1)
            next if max_bytes && bytes + added_bytes > max_bytes

            lines << line
            bytes += added_bytes
          end
          next prompt if lines.empty?

          payload[:injected_count] = lines.size
          payload[:skipped_count] -= lines.size
          payload[:injected_bytes] = bytes
          "#{prompt}#{prefix}#{lines.join("\n")}#{suffix}"
        end
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
