# frozen_string_literal: true

# Recall quality harness: measures recall@k hit-rate on the labelled fixtures.
# Uses whatever store/embedder is configured. With the default NullEmbedder this only
# exercises the mechanics — for meaningful numbers configure a semantic embedder, e.g.:
#
#   Engram.configure { |c| c.embedder = Engram::Adapters::RubyLLMEmbedder.new }
#   ruby eval/run.rb

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "engram"
require_relative "fixtures"

# Use a real semantic embedder for honest numbers (requires the ruby_llm gem + API key):
#   ENGRAM_EMBEDDER=ruby_llm ENGRAM_EMBED_MODEL=text-embedding-3-small ruby eval/run.rb
if ENV["ENGRAM_EMBEDDER"] == "ruby_llm"
  require "ruby_llm"
  Engram.configure do |c|
    c.embedder = Engram::Adapters::RubyLLMEmbedder.new(
      model: ENV.fetch("ENGRAM_EMBED_MODEL", "text-embedding-3-small")
    )
  end
end

k = Integer(ENV.fetch("K", "3"))
scope = "eval"
store = Engram.config.store
embedder = Engram.config.embedder

Engram::EVAL_FIXTURES[:memories].each do |content|
  store.add(Engram::Record.new(content: content, scope: scope, embedding: embedder.embed(content)))
end

recall = Engram::UseCases::Recall.new(store: store, embedder: embedder)

hits = 0
queries = Engram::EVAL_FIXTURES[:queries]
queries.each do |q|
  results = recall.call(q[:query], scope: scope, limit: k).map(&:content)
  hit = (results & q[:relevant]).any?
  hits += 1 if hit
  puts "#{hit ? "PASS" : "FAIL"}  #{q[:query]}"
  puts "      -> #{results.join(" | ")}"
end

puts
puts format("recall@%d hit-rate: %.0f%% (%d/%d)", k, 100.0 * hits / queries.size, hits, queries.size)
if embedder.is_a?(Engram::Adapters::NullEmbedder)
  puts "NOTE: NullEmbedder is not semantic — configure a real embedder for meaningful results."
end

# --- Consolidation: deterministic dedup check (heuristic consolidator) ---
puts
puts "Consolidation (heuristic dedup):"
dedup_store = Engram::Adapters::InMemoryStore.new
consolidator = Engram::Consolidators::HeuristicConsolidator.new(store: dedup_store)

def candidate_for(text, embedder)
  Engram::Record.new(content: text, scope: "eval", embedding: embedder.embed(text))
end

fact = "User's subscription tier is Pro"
dedup_store.add(candidate_for(fact, embedder))

duplicate = consolidator.reconcile_all(candidates: [candidate_for(fact, embedder)], scope: "eval").first.action
novel = consolidator.reconcile_all(candidates: [candidate_for("User lives in Berlin", embedder)], scope: "eval").first.action

puts "  #{duplicate == :noop ? "PASS" : "FAIL"}  duplicate fact -> #{duplicate}"
puts "  #{novel == :add ? "PASS" : "FAIL"}  novel fact     -> #{novel}"
