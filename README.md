# Engram

Long-term memory for AI agents in Ruby — stored in **your own** Postgres.

Engram lets an agent remember a user across sessions. It recalls the facts relevant to the
current message and injects them into the prompt, so the model stops asking the same
questions twice. No external memory-as-a-service: your memories live in your database.

> Status: early but real. v0.1 shipped the recall + inject foundation; v0.2 adds the
> extract → consolidate pipeline that turns raw conversations into durable memories
> automatically.

## Why

LLMs are stateless. Every request starts from zero, so an assistant forgets that the user
is on the Pro plan, is vegetarian, or already tried clearing the cache. The usual fixes
fall short: stuffing whole transcripts into the prompt is expensive and noisy, and plain
RAG retrieves documents, not personal facts. Engram is the memory layer in between.

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
bundle exec rake eval      # recall quality harness (precision@k)
```

Integration tests exercise the real Postgres + pgvector adapter (tagged `:integration`,
skipped by default):

```bash
DATABASE_URL=postgres://postgres:postgres@localhost:5432/engram_test \
  bundle exec rspec --tag integration
```

For honest recall numbers, run the eval with a real embedder instead of the test stub:

```bash
ENGRAM_EMBEDDER=ruby_llm ruby eval/run.rb   # needs the ruby_llm gem + an API key
```

## Roadmap

- v0.1 (done): recall + inject foundation, adapters, Rails + RubyLLM integration.
- v0.2 (done): extract and consolidate (ADD / UPDATE / FORGET), background jobs.
- later: reranking and decay, memory types per policy, additional storage backends, eval benchmarks.

## License

MIT. See [LICENSE.txt](LICENSE.txt).
