# frozen_string_literal: true

module Engram
  # The friendly facade. Bound to one `scope` (an owner), it wires the configured store
  # and embedder into the use cases. This is what `user.memory` returns in Rails.
  class Memory
    attr_reader :scope

    def initialize(scope:, store: Engram.config.store, embedder: Engram.config.embedder)
      @scope = scope
      @store = store
      @embedder = embedder
    end

    # Persist a memory record of the given kind. Returns nil when the configured
    # persistence policy rejects the record.
    def add(content, kind: :fact, importance: 1.0, metadata: {})
      Engram::Instrumentation.instrument("add", Engram::Instrumentation.payload(scope: scope, store: @store, kind: kind)) do
        embedding = @embedder.embed(content)
        record = Record.new(
          content: content,
          scope: scope,
          embedding: embedding,
          kind: kind,
          importance: importance,
          metadata: metadata
        )
        persist(record)
      end
    end

    # Return the most relevant memories for a query.
    def recall(query, limit: Engram.config.default_limit, kinds: nil)
      UseCases::Recall.new(
        store: @store,
        embedder: @embedder,
        importance_weight: Engram.config.importance_weight,
        recency_weight: Engram.config.recency_weight,
        recency_halflife: Engram.config.recency_halflife,
        touch: Engram.config.touch_on_recall
      ).call(query, scope: scope, limit: limit, kinds: kinds)
    end

    # Recall, then inject into a prompt string.
    def inject_into(prompt, query:, limit: Engram.config.default_limit, kinds: nil)
      memories = recall(query, limit: limit, kinds: kinds)
      UseCases::Inject.new.call(prompt: prompt, memories: memories)
    end

    # Derive memories from a conversation turn and consolidate them (v0.2).
    # `messages` is an Array of {role:, content:} hashes (or plain strings).
    # Returns the Array<Decision> applied. Requires a configured Completion.
    def observe(messages, completion: Engram.config.completion)
      if completion.nil?
        raise Engram::Error, "observe requires a Completion. Set Engram.config.completion."
      end

      UseCases::Observe.new(
        store: @store,
        extractor: build_extractor(completion),
        consolidator: build_consolidator(completion),
        processed_turns: Engram.config.processed_turns,
        embedder: @embedder
      ).call(
        messages: messages,
        scope: scope,
        idempotency_key: TurnDigest.digest(scope: scope, messages: messages)
      )
    end

    # Enqueue observation as a background job (Rails only).
    def observe_later(messages)
      unless defined?(Engram::ObserveJob)
        raise Engram::Error, "observe_later needs ActiveJob (Rails). Use #observe outside Rails."
      end

      Engram::Instrumentation.instrument(
        "observe_later",
        Engram::Instrumentation.payload(scope: scope, store: @store, message_count: messages.size)
      ) do
        Engram::ObserveJob.perform_later(scope, messages)
      end
    end

    def all
      @store.all(scope: scope)
    end

    # Recompute embeddings (and embedding metadata) for memories in the scope.
    # When `stale_only` is true, only records whose current metadata does not match the
    # active embedder are rebuilt.
    def rebuild_embeddings(stale_only: true, batch_size: 100)
      UseCases::RebuildEmbeddings.new(store: @store, embedder: @embedder).call(
        scope: scope,
        stale_only: stale_only,
        batch_size: batch_size
      )
    end

    # Prune stale memories. `older_than` is a duration in seconds; `min_importance` keeps
    # memories at or above that importance even when old. Returns the forgotten records.
    def forget_stale(older_than:, min_importance: Float::INFINITY)
      UseCases::Forget.new(store: @store)
        .call(scope: scope, older_than: older_than, min_importance: min_importance)
    end

    private

    def persist(record)
      Persistence.new(store: @store, embedder: @embedder).add(record)
    end

    def build_extractor(completion)
      Extractors::LLMExtractor.new(
        completion: completion,
        embedder: @embedder,
        min_confidence: Engram.config.extraction_min_confidence
      )
    end

    def build_consolidator(completion)
      case Engram.config.consolidator
      when :llm
        Consolidators::LLMConsolidator.new(store: @store, completion: completion)
      else
        Consolidators::HeuristicConsolidator.new(store: @store)
      end
    end
  end
end
