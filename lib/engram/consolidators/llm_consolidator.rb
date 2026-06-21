# frozen_string_literal: true

require "json"

module Engram
  module Consolidators
    # LLM-as-judge consolidation. For each candidate it gathers the nearest existing
    # memories (vector pre-filter) and asks the model, in a single batched call, what to
    # do: add / update / forget / noop.
    class LLMConsolidator
      include Ports::Consolidator

      SYSTEM = <<~PROMPT
        You maintain a user's long-term memory. For each candidate fact, decide how it
        relates to the existing memories provided:
          - "add":    genuinely new information
          - "update": supersedes a specific existing memory (e.g. a changed preference)
          - "forget": an existing memory is now contradicted or obsolete
          - "noop":   already known, or not worth storing
        Use "update"/"forget" only with the id of an existing memory shown for that candidate.
        Return one decision per candidate, referencing it by its index.
      PROMPT

      # Shaped for OpenAI strict structured outputs: every object sets
      # additionalProperties: false and lists all of its properties in `required`. target_id
      # is nullable because add/noop decisions reference no existing memory.
      SCHEMA = {
        type: "object",
        additionalProperties: false,
        properties: {
          decisions: {
            type: "array",
            items: {
              type: "object",
              additionalProperties: false,
              properties: {
                index: {type: "integer"},
                action: {type: "string", enum: %w[add update forget noop]},
                target_id: {type: %w[integer null]},
                reason: {type: "string"}
              },
              required: %w[index action target_id reason]
            }
          }
        },
        required: %w[decisions]
      }.freeze

      def initialize(store:, completion:, neighbors: 5)
        @store = store
        @completion = completion
        @neighbors = neighbors
      end

      def reconcile_all(candidates:, scope:)
        candidates = Array(candidates)
        return [] if candidates.empty?

        result = @completion.complete(
          system: SYSTEM,
          user: JSON.generate(payload(candidates, scope)),
          schema: SCHEMA
        )
        map_decisions(decisions(result), candidates)
      end

      private

      def payload(candidates, scope)
        items = candidates.each_with_index.map do |candidate, index|
          existing = Engram::EmbeddingMetadata.search(
            @store,
            embedding: candidate.embedding,
            embedding_metadata: Engram::EmbeddingMetadata.extract(candidate.metadata),
            scope: scope,
            limit: @neighbors
          )
          {
            index: index,
            candidate: candidate.content,
            existing: existing.map { |r| {id: r.id, content: r.content} }
          }
        end
        {candidates: items}
      end

      def decisions(result)
        return [] unless result.is_a?(Hash)

        result["decisions"] || result[:decisions] || []
      end

      def map_decisions(raw, candidates)
        raw.filter_map do |decision|
          decision = decision.transform_keys(&:to_s)
          index = decision["index"]
          next unless index && candidates[index]

          Engram::Decision.new(
            action: (decision["action"] || "noop").to_sym,
            candidate: candidates[index],
            target_id: decision["target_id"],
            reason: decision["reason"]
          )
        end
      end
    end
  end
end
