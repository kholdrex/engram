# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.3.0] — idempotency, smarter recall, forgetting

### Added
- Idempotent observation: `ProcessedTurns` port, `InMemoryProcessedTurns`,
  `Rails::CacheProcessedTurns`, and a stable `TurnDigest`. A repeated turn is skipped.
- Recall ranking options: `importance_weight`, `recency_weight`, and `recency_halflife`,
  blended on top of vector similarity (defaults keep plain similarity search).
- `touch_on_recall` and `MemoryStore#touch` to update `last_accessed_at` on recall.
- `UseCases::Forget` and `Memory#forget_stale` to prune memories by age and importance.

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
