# frozen_string_literal: true

module Engram
  module Extractors
    # Derives durable, user-specific facts from a conversation turn via an LLM.
    class LLMExtractor
      include Ports::Extractor

      SYSTEM = <<~PROMPT
        You extract durable, user-specific facts worth remembering across future sessions.
        Rules:
        - Only stable facts about the user (preferences, attributes, decisions, history).
        - Ignore ephemeral chit-chat, questions, and the assistant's own messages.
        - Normalize each fact to a terse third-person statement (e.g. "User is on the Pro plan").
        - Classify kind as fact, preference, instruction, or episodic.
        - Do not extract secrets, API keys, passwords, tokens, or transient task progress.
        - Set confidence in [0,1]; importance in [0,1].
        Return an empty list if there is nothing worth remembering.
      PROMPT

      # Shaped for OpenAI strict structured outputs: every object sets
      # additionalProperties: false and lists all of its properties in `required`. The
      # extractor still defends against missing/empty fields, so requiring them here only
      # constrains the model's output, it does not change downstream behaviour.
      SCHEMA = {
        type: "object",
        additionalProperties: false,
        properties: {
          facts: {
            type: "array",
            items: {
              type: "object",
              additionalProperties: false,
              properties: {
                content: {type: "string"},
                kind: {type: "string", enum: %w[fact preference instruction episodic semantic]},
                importance: {type: "number"},
                confidence: {type: "number"}
              },
              required: %w[content kind importance confidence]
            }
          }
        },
        required: %w[facts]
      }.freeze

      def initialize(completion:, embedder:, min_confidence: 0.5)
        @completion = completion
        @embedder = embedder
        @min_confidence = min_confidence
      end

      def extract(messages:, scope:)
        result = @completion.complete(system: SYSTEM, user: transcript(messages), schema: SCHEMA)
        facts(result).filter_map do |fact|
          fact = fact.transform_keys(&:to_s)
          content = fact["content"].to_s.strip
          next if content.empty?
          next if (fact["confidence"] || 1.0).to_f < @min_confidence

          embedding = @embedder.embed(content)
          Engram::EmbeddingMetadata.attach(Engram::Record.new(
            content: content,
            scope: scope,
            kind: fact["kind"] || "fact",
            importance: (fact["importance"] || 1.0).to_f,
            metadata: {confidence: (fact["confidence"] || 1.0).to_f},
            embedding: embedding
          ), embedder: @embedder)
        end
      end

      private

      def facts(result)
        return [] unless result.is_a?(Hash)

        result["facts"] || result[:facts] || []
      end

      def transcript(messages)
        Array(messages).map { |m| line(m) }.join("\n")
      end

      def line(message)
        if message.is_a?(Hash)
          role = message[:role] || message["role"] || "user"
          "#{role}: #{message[:content] || message["content"]}"
        else
          "user: #{message}"
        end
      end
    end
  end
end
