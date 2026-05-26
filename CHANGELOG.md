# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Canonical memory kinds: `fact`, `preference`, `instruction`, and `episodic`.
- Typed recall filters via `kinds:` for `Memory#recall` and prompt injection.
- Typed XML-like memory injection with escaped content and `kind` attributes.
- Default `PersistencePolicy` that rejects obvious secrets/tokens/passwords and transient
  task-progress memories before storage.
- `before_persist` hook and caller-provided denylist redaction support.
- Documentation for provider-agnostic model configuration, pgvector setup, production
  readiness, and prompt-injection safety.

### Changed
- Legacy `semantic` memories are normalized to `fact` in Ruby and included by `kinds: [:fact]`
  filters for compatibility.
- `Memory#add` returns `nil` when the persistence policy rejects a memory.
- Redacted or otherwise modified records have embeddings recomputed before storage.
- Rails generator default memory kind is now `fact` instead of `semantic`.
- README status, feature overview, Rails setup, development commands, and roadmap now reflect
  the current pre-1.0 API surface.

### Security
- Memory persistence rejects common secret and credential patterns by default.
- Documentation now calls out that recalled memories are untrusted user-derived context, not
  system instructions or authorization facts.

### Upgrade notes
- Existing rows with `kind = "semantic"` continue to work: Engram treats them as `fact` at
  read time for recall filters; existing rows are not rewritten. New generated migrations
  default to `fact`.
- If application code assumed `Memory#add` always returns a record, handle `nil` for rejected
  memories.
- If you change embedding providers/models, verify the generated pgvector column dimension
  matches the embedding vector length.

## [0.3.0] - 2026-05-25 — idempotency, smarter recall, forgetting

### Added
- Idempotent observation: `ProcessedTurns` port, `InMemoryProcessedTurns`,
  `Rails::CacheProcessedTurns`, and a stable `TurnDigest`. A repeated turn is skipped.
- Recall ranking options: `importance_weight`, `recency_weight`, and `recency_halflife`,
  blended on top of vector similarity (defaults keep plain similarity search).
- `touch_on_recall` and `MemoryStore#touch` to update `last_accessed_at` on recall.
- `UseCases::Forget` and `Memory#forget_stale` to prune memories by age and importance.

### Fixed
- Extractor and consolidator JSON schemas now satisfy OpenAI strict structured outputs
  (`additionalProperties: false`, every property in `required`, nullable `target_id`), so the
  RubyLLM + OpenAI path works end to end. A schema-conformance spec guards against regressions.

## [0.2.0] — extract → consolidate

### Added
- `Completion` port for structured LLM calls; adapters `RubyLLMCompletion` and `FakeCompletion`.
- `Extractors::LLMExtractor` — derives durable, user-specific facts from a turn (schema + confidence threshold).
- `Consolidators::HeuristicConsolidator` (deterministic, dedup) and `Consolidators::LLMConsolidator`
  (LLM-as-judge, batched ADD / UPDATE / FORGET / NOOP).
- `UseCases::Observe` orchestrator; `Memory#observe` / `Memory#observe_later`.
- `Decision` value object; `MemoryStore#update`/`#delete`; record ids.
- Rails `ObserveJob` for background observation.
- Consolidation dedup check in the eval harness.

## [0.1.0] — recall + inject foundation

### Added
- Ports-and-adapters core: `Record`, `MemoryStore`/`Embedder` ports, `Recall`/`Inject` use cases.
- Built-in adapters: `InMemoryStore`, `NullEmbedder` (zero-config, test-friendly).
- Optional adapters: `PgvectorStore` (neighbor), `RubyLLMEmbedder`.
- `Engram::Memory` facade and Rails `has_memory` macro.
- RubyLLM integration: `Engram.with_memory(chat, memory:)`.
- Install generator (migration + initializer + model).
