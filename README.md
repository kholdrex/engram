# Engram

Long-term memory for AI agents in Ruby — stored in **your own** Postgres.

Engram lets an agent remember a user across sessions. It recalls the facts relevant to the
current message and injects them into the prompt, so the model stops asking the same
questions twice. No external memory-as-a-service: your memories live in your database.

> Status: pre-1.0. Two things are implemented and tested: recall with prompt injection
> (v0.1), and extracting and consolidating memories from conversations (v0.2). The public
> API may still change before 1.0.

## Why

LLMs are stateless. Every request starts from zero, so an assistant forgets that the user
is on the Pro plan, is vegetarian, or already tried clearing the cache. The usual fixes
fall short: stuffing whole transcripts into the prompt is expensive and noisy, and plain
RAG retrieves documents, not personal facts. Engram is the memory layer in between.

## Before and after

Without a memory layer, every session starts blank:

```text
Day 1
  User:  I'm on the Pro plan, and please keep answers short.
  Agent: Got it.

Day 5 (new session — the model has forgotten)
  User:  Why am I being rate limited?
  Agent: Which plan are you on? Can you share more about your setup?
```

With engram, the facts from day 1 are recalled and added to the prompt before the model answers:

```ruby
# Day 1: engram extracts and stores
#   "User is on the Pro plan", "User prefers short answers"
current_user.memory.observe(conversation)

# Day 5: engram recalls the relevant facts, then asks the model
chat = Engram.with_memory(RubyLLM.chat, memory: current_user.memory)
chat.ask("Why am I being rate limited?")
```

```text
  Agent: You're on the Pro plan, which has a per-minute request cap, and you're
         hitting it. (Kept short, as you prefer.)
```

## Installation

```ruby
# Gemfile
gem "engram"
```

The core has **zero runtime dependencies**. Optional adapters need:

- `Engram::Adapters::PgvectorStore` → `neighbor` + ActiveRecord + Postgres/pgvector
- `Engram::Adapters::RubyLLMEmbedder` → `ruby_llm`

## Quick start (plain Ruby)

```ruby
require "engram"

memory = Engram::Memory.new(scope: "user:42")  # zero-config: in-memory + null embedder

memory.add("Subscription tier is Pro")
memory.add("Prefers concise answers")

memory.recall("why am I being rate limited?")
# => [#<Engram::Record content="Subscription tier is Pro" ...>]
```

## Rails

```bash
bin/rails generate engram:install   # migration + initializer + model
bin/rails db:migrate
```

```ruby
class User < ApplicationRecord
  has_memory      # scope defaults to "user:<id>"
end

current_user.memory.add("Works at Acme Corp")
current_user.memory.recall("where does the user work?")
```

## RubyLLM integration

```ruby
chat = Engram.with_memory(RubyLLM.chat, memory: current_user.memory)
chat.ask("why am I being rate limited?")
# recall + inject happen automatically before the model sees the message
```

## Automatic memory (v0.2)

Instead of adding facts by hand, let engram derive them from a conversation turn. It
extracts candidate facts, then consolidates them against what's already known —
add / update / forget / noop.

```ruby
Engram.configure do |config|
  config.completion = Engram::Adapters::RubyLLMCompletion.new
  config.consolidator = :llm   # or :heuristic for deterministic, no-LLM dedup
end

memory = current_user.memory
memory.observe([
  {role: "user", content: "I switched from the Free plan to Pro"}
])
# extracts "User is on the Pro plan", and if a "Free plan" memory exists, updates it
```

In Rails, run it off the request path: `current_user.memory.observe_later(messages)`.

## Memory kinds and persistence policy

Every memory has a normalized `kind`:

- `fact` — stable attributes or state
- `preference` — user preferences
- `instruction` — durable instructions about how to work with the user
- `episodic` — durable history worth preserving

The legacy `semantic` kind is still accepted and normalized to `fact` for compatibility.
Recall can be narrowed to specific kinds when you only want preferences, instructions, or
another subset:

```ruby
memory.recall("how should I answer?", kinds: [:preference, :instruction])
memory.inject_into(prompt, query: "how should I answer?", kinds: [:preference, :instruction])
```

`kinds: []` is treated the same as omitting `kinds`, so callers that build filters
programmatically do not accidentally suppress all recall results.

Injected memories are rendered as typed XML-like elements with escaped content, which keeps
memory text clearly delimited from the rest of the prompt:

```xml
<engram-memories>
<engram-memory kind="preference">Prefers concise answers</engram-memory>
</engram-memories>
```

For compatibility during migration, `kinds: [:fact]` also includes legacy rows persisted
with the old `semantic` kind value.

Before storage, Engram applies a default persistence policy that rejects obvious secrets
(API keys, tokens, passwords) and transient task-progress updates. If a memory is rejected,
`Memory#add` returns `nil`. You can add a custom redaction or policy hook; when redaction
changes content, Engram recomputes the embedding before storage:

```ruby
Engram.configure do |config|
  config.before_persist = lambda do |record|
    record.with(content: record.content.gsub(/billing@example\.test/, "[REDACTED]"))
  end

  config.persistence_policy = Engram::PersistencePolicy.new(
    denylist_patterns: [/internal-ticket-\d+/i]
  )
end
```

## Tuning and maintenance (v0.3)

Observation is idempotent per turn: observing the same messages twice does nothing the
second time, so retries do not create duplicate memories or repeat LLM calls. In Rails,
use a persistent store so this also holds across job retries and processes:

```ruby
Engram.configure do |c|
  c.processed_turns = Engram::Rails::CacheProcessedTurns.new
end
```

Recall is plain similarity search by default. You can blend in importance and recency:

```ruby
Engram.configure do |c|
  c.importance_weight = 0.3
  c.recency_weight = 0.2
  c.touch_on_recall = true   # update last_accessed_at when a memory is recalled
end
```

Prune memories you no longer need:

```ruby
# Forget memories untouched for 90 days, but keep anything important
current_user.memory.forget_stale(older_than: 90 * 24 * 60 * 60, min_importance: 0.7)
```

## How it works

A loop around your LLM calls. Before a call: recall relevant memories and inject them.
After a turn (v0.2): extract new facts, consolidate them, and persist. The store
(Postgres + pgvector) is the only thing that persists between sessions.

## Architecture

Ports-and-adapters. A pure-Ruby core depends on `MemoryStore` and `Embedder` ports;
pgvector, RubyLLM, and Rails are swappable adapters. This keeps the domain fast to test
(in-memory + null adapters, no DB or API keys) and lets the v0.2 `Extractor`/`Consolidator`
slot in without rework.

## Development

```bash
bundle install
bundle exec rspec          # unit suite (no DB, no network)
bundle exec standardrb     # lint
bundle exec rake eval      # local quality harness (recall, extraction, consolidation)
```

Integration tests exercise the real Postgres + pgvector adapter (tagged `:integration`,
skipped by default):

```bash
DATABASE_URL=postgres://postgres:postgres@localhost:5432/engram_test \
  bundle exec rspec --tag integration
```

For honest recall numbers, run the eval with a real embedder instead of the test stub.
`ruby_llm` is not a dependency, so install it separately first:

```bash
gem install ruby_llm
ENGRAM_EMBEDDER=ruby_llm OPENAI_API_KEY=... ruby eval/run.rb

# Optional: exercise the live completion adapter for manual inspection.
# Exact extraction/consolidation quality scoring is not implemented yet.
ENGRAM_COMPLETION=ruby_llm ENGRAM_COMPLETION_MODEL=gpt-4o-mini OPENAI_API_KEY=... ruby eval/run.rb
```

The default eval path is deterministic and network-free, so it is safe to run in CI as a
smoke test. It reports recall@k over labelled relevant memories, a labelled
precision proxy@k, near-distractor retrieval rate, contradiction-pair full recall,
extraction structured-output parsing cases, consolidation decision cases, and a heuristic
duplicate-add baseline. Negative queries are printed for inspection, but top-k recall
currently has no similarity threshold, so the harness does not report a hallucination
rate. Treat the default NullEmbedder recall numbers as a mechanics check, not as a
semantic retrieval benchmark.

## Roadmap

- v0.1 (done): recall + inject foundation, adapters, Rails + RubyLLM integration.
- v0.2 (done): extract and consolidate (ADD / UPDATE / FORGET), background jobs.
- v0.3 (done): idempotent observation, importance/recency recall, forgetting and decay.
- v0.4 (in progress): memory kinds, persistence policy, typed recall filters, and safer injection.
- later: additional storage backends and larger eval benchmarks.

## License

MIT. See [LICENSE.txt](LICENSE.txt).
