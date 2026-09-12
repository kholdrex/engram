# Production readiness review

Reviewed 2026-09-12 against `main` at `61517b5` (Engram 0.6.0).

Engram already has a useful production foundation: an optional Postgres adapter, scope-bound
storage, background observation, retry coordination, embedding compatibility checks, and
extensive persistence/provenance validation. The most immediate opportunity is controlling
which memories reach the model and how much context they consume.

## Research and implications

Reddit is useful for discovering practitioner concerns, but these discussions are anecdotal,
not controlled benchmarks or evidence of how often a failure occurs.

| Evidence | Implication for Engram |
| --- | --- |
| An [r/AI_Agents discussion](https://www.reddit.com/r/AI_Agents/comments/1tqyy9c/ai_agents_dont_have_an_intelligence_problem_they/) describes irrelevant retrieval, stale state, contradictions, and difficulty identifying which memory caused a failure. | Allow recall to abstain, expose content-free selection metrics, and evaluate negative queries. |
| An [r/Rag discussion](https://www.reddit.com/r/Rag/comments/1vdhtn5/a_list_of_how_different_vector_databases_handle/) highlights filtered searches returning too few results. | Benchmark searches within realistic owner scopes; a global nearest-neighbor test is insufficient. |
| [Anthropic's context engineering guidance](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) recommends a small set of useful context and treats attention as a finite resource. | Add an explicit injection budget while preserving complete memories and delimiters. |
| The [pgvector documentation](https://github.com/pgvector/pgvector#filtering) confirms that approximate-index filtering can reduce result counts. | Document tuning and measurement; do not silently change host database settings. |
| [RubyLLM's streaming contract](https://rubyllm.com/streaming/) delivers chunks through the `ask` block and returns the completed response. | Preserve the block, provider options, and final response through Engram's wrapper. |

These are design inputs, not claims that a similarity threshold establishes truth or resolves
contradictions. The implementation choices below follow from inspecting Engram's current code.

## Implemented in this change

1. **Relevance threshold.** `Memory#recall`, `inject_into`, and `with_memory` accept
   `min_similarity`. It filters the retrieved candidate pool before importance/recency
   reranking, so unrelated memories cannot qualify solely through high importance. Rejected
   candidates are not touched. `config.recall_min_similarity` defaults to nil.
2. **Bounded context.** `max_bytes` counts the full appended section after escaping, including
   separators, header, and tags. It skips complete memories that do not fit, preserves the
   order of those retained, and leaves the original prompt unchanged when none fit.
   `config.injection_max_bytes` defaults to nil. Bytes do not represent a model's token count.
3. **Chat integration fixes.** Streaming callbacks reach the underlying chat. Fluent methods
   returning that same chat preserve the wrapper, preventing accidental loss of memory on
   chained configuration calls. Other return values and errors pass through.
4. **Measurable behavior.** Recall reports candidate, filtered, and result counts. Injection
   reports input, injected, and skipped counts plus appended bytes. The eval accepts
   `MIN_SIMILARITY` and measures negative-query false positives and abstentions alongside
   positive recall. No runtime query text, vectors, or memory content is added to these metrics.

No storage migration, provider call, or new runtime dependency is needed for these controls.
Existing defaults remain unchanged. Recall limits now require non-negative integers; the
changelog records this validation change. Zero limits and zero injection budgets avoid
unnecessary embedding/search work.

## Adoption and evaluation

Start with labelled examples from the host application's domain: relevant questions,
unrelated questions, near distractors, changed preferences, contradictory facts, and similar
memories belonging to different owners. Use sanitized fixtures and the intended embedding
model. `NullEmbedder` is a deterministic mechanics test, not a semantic quality benchmark.

Compare a baseline with several thresholds:

```sh
bundle exec rake eval
MIN_SIMILARITY=0.5 bundle exec rake eval

# With separately installed RubyLLM and provider configuration:
bundle exec rake eval:real
MIN_SIMILARITY=0.5 bundle exec rake eval:real
```

The value 0.5 is illustrative. Select it using positive recall, negative-query false positives,
and downstream answer quality together. A high threshold can make irrelevant retrieval look
excellent by returning nothing; positive coverage must remain acceptable. The small bundled
fixture set cannot certify an application's production quality.

Set an injection byte cap that fits the application's context allocation. Monitor zero-result
recalls, the fraction of retrieved memories excluded by the threshold, budget skips, appended
bytes, and p95 latency. Threshold filtering cannot recover candidates missed by approximate
search. The cap covers the added memory section, not the original prompt or chat history.

## Next priorities

| Priority | Gap observed in the repository | Proposed follow-up and acceptance evidence |
| --- | --- | --- |
| High | Observation decisions and the completed marker are not one transaction. | Design transactional observation/outbox coordination; demonstrate retries after a crash between writes without duplicate side effects. Cache leases alone do not provide exactly-once persistence. |
| High | Stale pruning uses activity timestamps, not fact validity; consolidation has no persisted supersession history. | Add an explicit expiry/supersession model; evaluate preference changes and conflicting facts over multiple sessions. |
| High | Deletion exists on the store port, but the facade only exposes stale pruning and source lookup. | Add deliberate, scope-bound forget-by-id/source APIs and paginated export; test owner isolation and concurrent changes. |
| Medium | Recall is dense-vector only. | Evaluate hybrid lexical/vector retrieval on exact names, error codes, and identifiers before expanding the search contract. |
| Medium | Semantic quality is not measured by the default CI embedder. | Establish a versioned real-provider benchmark with recall, negative-query false positives, latency, cost, and database-size scenarios. |
| Medium | Source impact and grounding reporting enumerate the scope. | Add indexed/paginated store capabilities and measure large-scope query cost while retaining legacy adapter support. |

The next change should follow measured host-app needs. This pass addresses context selection
and chat usability; it does not establish semantic truth, crash-proof persistence, or
production-scale throughput.
