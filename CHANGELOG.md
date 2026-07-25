# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- `Engram::Memory#grounding_report` (and `Engram::UseCases::GroundingReport`) returns frozen,
  scope-bound record counts by weakest source alignment, with legacy or unrecognized provenance
  counted as unattributed and no record or source text exposed.
- Add an immutable host-supplied source-text contract that validates provenance source identity
  and Unicode-codepoint span bounds, and resolves authorized supporting text without retaining
  source transcripts.
- Optional `Engram::Extraction` results let custom extractors attach versioned source
  provenance while remaining compatible with plain `Engram::Record` results.
- `Engram::Record#provenance` exposes understood supporting source IDs, alignments, and spans
  on recalled records while preserving tolerant reads for legacy and future schemas.
- `Engram::Memory#memories_from_source` (and `Engram::UseCases::SourceImpact`) return the
  records in a scope whose provenance references an exact host source. `source_id` and
  `source_type` must each be a non-blank String and are matched exactly without trimming or
  normalization. The lookup is scope-bound and returns only records, never source
  text; source IDs are references, not an authorization boundary. Legacy, malformed, and
  future-schema provenance do not match.

### Changed
- Persistence accepts records without provenance, rejects structurally ungrounded provenance
  by default (configurable only with the exact boolean `allow_ungrounded: true`), and fails closed on malformed or
  unknown future provenance during writes while keeping reads tolerant. Provenance validation
  does not verify source text, and source IDs are references rather than authorization
  boundaries. The built-in LLM extractor does not emit grounded provenance.
- Existing `before_persist` hooks may continue to transform record content or embeddings, but
  may neither add, remove, nor alter provenance; this restriction includes legacy records with
  no provenance.
- Extractors must return an `Array`; each result may be a plain `Engram::Record` or an
  `Engram::Extraction` carrying provenance.
- Custom consolidator decisions must reference the actual same-scope `Engram::Record` instance
  supplied for reconciliation and must treat both the candidates array and records as read-only.
  Engram now fails closed on collection replacement/reordering/iteration overrides and on
  security-relevant nested value, identity/alias/topology, frozen-state, custom-behavior, or
  hidden-state changes before destructive authorization. Arbitrary application metadata values
  remain opaque and preserve their identity without invoking equality or serialization behavior;
  provenance is independently parsed and integrity-protected.
  Substituted, modified, missing, malformed, or cross-scope candidates fail closed.
  `Observe` preflights the complete decision batch, including persistence policy and hook
  transformations, before beginning store mutations.

### Fixed
- Observation rejects extractor candidates with caller-supplied IDs, and `InMemoryStore#add`
  always allocates a fresh ID like the pgvector adapter, preventing same- or cross-scope record
  replacement through add semantics.
- `forget` now separates destructive provenance authorization from write-content filtering and
  redaction, so secret or transient memories can be deleted. Custom policies may implement
  `allow_destructive?` with a strict boolean return; write-only policies no longer authorize
  deletion through their `call` result.

## [0.5.0] - 2026-07-17

### Added
- Embedding provenance metadata is stored with new memories so applications can detect model
  and dimension drift during store search result validation.
- `Memory#rebuild_embeddings` and `Engram::UseCases::RebuildEmbeddings` for scoped,
  deterministic rebuilding of stale vectors plus provenance metadata.
- Added a focused rake task `engram:rebuild_embeddings` with batch control and optional
  forced full-scope rebuild mode for recovery after provider/model changes. The task is
  packaged with the gem and loaded into host Rails apps by the Railtie, where it depends on
  `:environment` so app initializers run first. `STALE_ONLY` accepts `false`, `0`, or `no`.

### Changed
- `MemoryStore` mutations now require an explicit `scope:` and enforce the `(scope, id)` boundary
  for update, delete, and touch operations. Custom stores must adopt the new scoped signatures;
  `update` returns the updated record or raises `Engram::Error`, while delete and touch return an
  affected-row count.
- **Breaking (pre-1.0):** the `ProcessedTurns` port migrated from the previous check/mark API
  to `claim`, `complete`, `release`, and `completed?`; custom adapters must implement the new
  claim lifecycle. A successful claim returns a truthy opaque token.
- Observation idempotency now uses atomic, scope-aware claims with an in-progress lease and
  completed state. `InMemoryProcessedTurns` is thread-safe and releases failures immediately.
  Generic cache release is a no-op until lease expiry because ActiveSupport cache has no atomic
  compare-and-delete; completion never deletes a possibly newer claim. Completed markers
  suppress later calls only for their configured `ttl`. A failed completion write leaves the
  lease to suppress work until expiry, after which already-applied work may replay. `lease_ttl`
  should cover the longest observation while remaining much shorter than `ttl`, and
  `Rails::CacheProcessedTurns` uses atomic `unless_exist` writes with separate claim and
  completion keys. This coordinates concurrent work but does not make multi-decision memory
  persistence and claim completion a crash-proof transaction. Lease expiry may permit overlap,
  so claims do not guarantee ownership, fencing, or exactly-once execution.
- Added API stability and migration posture documentation for pre-1.0 freeze planning, including public surface boundaries and legacy compatibility points.
- Store search result validation now raises a clear `Engram::Error` when stored embedding
  metadata or vector dimensions conflict with the active embedder, while legacy records without
  metadata remain searchable when their vector dimensions match the active embedder.
- Caller metadata keys named `_engram` are now reserved for Engram-owned embedding provenance;
  rename any application metadata stored under that key before adding new memories.
- `RubyLLMEmbedder` now requests explicitly configured `dimensions:` from the provider (on
  RubyLLM versions that support the option) and validates every returned vector against the
  configured dimensions, raising a clear `Engram::Error` on mismatch. Previously the option
  was recorded in metadata but never sent or checked, so a mismatch surfaced later as opaque
  pgvector insert failures. If you use a model whose native vector size differs from 1536,
  set `dimensions:` to that model's actual output size.

### Fixed
- `Observe` now raises `Engram::ObservationInProgressError` when a turn is claimed but not
  completed, rather than reporting a successful no-op. `ObserveJob` retries this error with
  backoff that outlasts the default claim lease; direct callers should handle it as retryable.
- Stale detection in `rebuild_embeddings` now compares against the embedder's declared
  dimensions instead of the stored record's vector length, so a dimensions-only embedder
  change marks existing rows stale. Previously the default stale-only rebuild silently
  skipped every row after such a change. Embedders that do not declare dimensions keep the
  previous record-length comparison.
- `LLMConsolidator` now ignores malformed decisions and rejects `update`/`forget` targets
  that were not shown to the model, preventing invalid model output from partially applying
  a turn. Cross-scope updates from custom consolidators still raise in `Observe`.

## [0.4.0] - 2026-06-06

### Added
- Canonical memory kinds: `fact`, `preference`, `instruction`, and `episodic`.
- Typed recall filters via `kinds:` for `Memory#recall` and prompt injection.
- Typed XML-like memory injection with escaped content and `kind` attributes.
- Default `PersistencePolicy` that rejects obvious secrets/tokens/passwords and transient
  task-progress memories before storage.
- `before_persist` hook and caller-provided denylist redaction support.
- Optional `ActiveSupport::Notifications` instrumentation around the observe/recall/inject
  pipeline (`*.engram` events) with a configurable `instrumentation_scope_identifier` for
  privacy-safe scope tagging. Stays a no-op when ActiveSupport is not loaded, so the core
  remains dependency-free.
- Documentation for provider-agnostic model configuration, pgvector setup, production
  readiness, prompt-injection safety, and real-provider eval smoke testing.
- `SECURITY.md` threat model covering prompt-injection boundaries, secret handling, and
  the untrusted-input posture of recalled memories.
- `rake eval:real` for RubyLLM-backed eval smoke runs that keep provider configuration
  delegated to RubyLLM.

### Changed
- Legacy `semantic` memories are normalized to `fact` in Ruby and included by `kinds: [:fact]`
  filters for compatibility.
- `Memory#add` returns `nil` when the persistence policy rejects a memory.
- Redacted or otherwise modified records have embeddings recomputed before storage.
- Rails generator default memory kind is now `fact` instead of `semantic`.
- Install generator and `create_engram_memories` template harden pgvector setup: clearer
  extension installation guidance, safer defaults, and explicit dimension handling.
- `InMemoryStore` and `PgvectorStore` enforce scope isolation defensively so recall, update,
  and delete operations cannot cross scopes even when callers pass mismatched ids.
- README status, feature overview, Rails setup, development commands, and roadmap now reflect
  the current pre-1.0 API surface.
- Real-provider eval setup delegates provider-specific RubyLLM configuration to RubyLLM
  instead of hardcoding credential environment variable names in Engram.
- Real-provider eval forces UTF-8 external encoding before loading RubyLLM so smoke runs work
  even when the shell locale defaults Ruby to US-ASCII.
- RubyLLM provider configuration failures now show an eval-specific setup hint instead of a raw
  provider stack trace.

### Security
- Memory persistence rejects common secret and credential patterns by default.
- Documentation now calls out that recalled memories are untrusted user-derived context, not
  system instructions or authorization facts.
- Published a memory security threat model in `SECURITY.md` covering the boundaries Engram
  enforces and the ones the host application must enforce.
- Store-level scope isolation guarantees prevent cross-scope memory leakage on misuse.

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
