# frozen_string_literal: true

# Quality harness for recall, extraction, and consolidation. The default path is
# network-free and CI-safe. For meaningful recall numbers, configure a semantic
# embedder with ENGRAM_EMBEDDER=ruby_llm. ENGRAM_COMPLETION=ruby_llm is a
# manual adapter smoke path, not an exact quality score.

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "engram"
require_relative "fixtures"

module Engram
  module Eval
    SCOPE = "eval"

    module_function

    def run
      configure_embedder
      embedder = Engram.config.embedder
      warn_if_null_embedder(embedder)

      puts "Recall:"
      run_recall(embedder)

      puts
      puts "Extraction (#{completion_mode} structured-output smoke):"
      extraction_ok = run_extraction(embedder)

      puts
      puts "Consolidation (#{completion_mode} judge smoke):"
      consolidation_ok = run_consolidation(embedder)

      puts
      puts "Consolidation (heuristic duplicate baseline):"
      heuristic_ok = run_heuristic_consolidation(embedder)

      exit(1) unless extraction_ok && consolidation_ok && heuristic_ok
    rescue => error
      raise unless ruby_llm_configuration_error?(error)

      abort ruby_llm_configuration_message(error)
    end

    def configure_embedder
      return unless ENV["ENGRAM_EMBEDDER"] == "ruby_llm"

      configure_ruby_llm!

      Engram.configure do |config|
        config.embedder = Engram::Adapters::RubyLLMEmbedder.new(
          model: ENV.fetch("ENGRAM_EMBED_MODEL", "text-embedding-3-small")
        )
      end
    end

    def configure_ruby_llm!
      ensure_utf8_external_encoding!

      unless defined?(RubyLLM)
        begin
          require "ruby_llm"
        rescue LoadError
          abort "ruby_llm is not installed (it is not a dependency of engram). " \
            "Run `gem install ruby_llm`, then re-run eval with the ruby_llm option."
        end
      end

      load_ruby_llm_setup!
    end

    def ensure_utf8_external_encoding!
      return if Encoding.default_external == Encoding::UTF_8

      Encoding.default_external = Encoding::UTF_8
    end

    def load_ruby_llm_setup!
      setup_path = ENV["ENGRAM_RUBY_LLM_SETUP"]
      return if setup_path.nil? || setup_path.empty?

      require File.expand_path(setup_path)
    end

    def ruby_llm_configuration_error?(error)
      defined?(RubyLLM::ConfigurationError) && error.is_a?(RubyLLM::ConfigurationError)
    end

    def ruby_llm_configuration_message(error)
      <<~MESSAGE
        RubyLLM provider configuration is missing or invalid: #{error.message}

        `rake eval:real` delegates provider setup to RubyLLM. Configure RubyLLM for your
        chosen provider, or set ENGRAM_RUBY_LLM_SETUP=/path/to/setup.rb to load setup code
        before the eval harness runs.
      MESSAGE
    end

    def run_recall(embedder)
      k = Integer(ENV.fetch("K", "3"))
      store = Engram::Adapters::InMemoryStore.new
      Engram::EVAL_FIXTURES[:memories].each do |content|
        store.add(record(content, embedder))
      end

      recall = Engram::UseCases::Recall.new(store: store, embedder: embedder)
      rows = Engram::EVAL_FIXTURES[:recall_queries].map do |fixture|
        results = recall.call(fixture[:query], scope: SCOPE, limit: k).map(&:content)
        evaluate_recall_row(fixture, results)
      end

      rows.each do |row|
        puts "  #{row[:label]}  #{row[:query]}"
        puts "        -> #{row[:results].join(" | ")}"
      end

      positives = rows.reject { |row| row[:negative] }
      negatives = rows.select { |row| row[:negative] }
      contradictions = rows.select { |row| row[:contradiction] }
      hit_count = positives.count { |row| row[:hit] }
      relevant_total = positives.sum { |row| row[:relevant_total] }
      relevant_retrieved = positives.sum { |row| row[:relevant_retrieved] }
      positive_retrieved = positives.sum { |row| row[:results].size }
      distractor_retrieved = positives.sum { |row| row[:distractor_retrieved] }
      distractor_total = positives.sum { |row| row[:distractor_total] }
      contradiction_hits = contradictions.count do |row|
        row[:relevant_retrieved] == row[:relevant_total]
      end

      null_embedder = null_embedder?(embedder)

      metrics = {
        hit_count: hit_count,
        positive_count: positives.size,
        relevant_retrieved: relevant_retrieved,
        relevant_total: relevant_total,
        positive_retrieved: positive_retrieved,
        distractor_retrieved: distractor_retrieved,
        distractor_total: distractor_total,
        contradiction_hits: contradiction_hits,
        contradiction_count: contradictions.size,
        negative_count: negatives.size,
        semantic_metrics_available: !null_embedder
      }

      puts
      if null_embedder
        puts format("  recall@%d: n/a (NullEmbedder, not semantic)", k)
        puts format("  hit-rate@%d: n/a (NullEmbedder, not semantic)", k)
        puts format("  labelled precision proxy@%d: n/a (NullEmbedder, not semantic)", k)
        puts "  near-distractor retrieval rate: n/a (NullEmbedder, not semantic)"
        puts "  contradiction pair full-recall rate: n/a (NullEmbedder, not semantic)"
      else
        puts format(
          "  recall@%d: %.1f%% (%d/%d relevant memories)",
          k,
          percent(relevant_retrieved, relevant_total),
          relevant_retrieved,
          relevant_total
        )
        puts format(
          "  hit-rate@%d: %.1f%% (%d/%d queries)",
          k,
          percent(hit_count, positives.size),
          hit_count,
          positives.size
        )
        puts format(
          "  labelled precision proxy@%d: %.1f%% (%d/%d positive-query results)",
          k,
          percent(relevant_retrieved, positive_retrieved),
          relevant_retrieved,
          positive_retrieved
        )
        puts format(
          "  near-distractor retrieval rate: %.1f%% (%d/%d labelled distractors)",
          percent(distractor_retrieved, distractor_total),
          distractor_retrieved,
          distractor_total
        )
        puts format(
          "  contradiction pair full-recall rate: %.1f%% (%d/%d labelled pairs)",
          percent(contradiction_hits, contradictions.size),
          contradiction_hits,
          contradictions.size
        )
      end
      puts format("  negative queries inspected: %d (top-k retrieval always returns rows)", negatives.size)
      metrics
    end

    def evaluate_recall_row(fixture, results)
      relevant = fixture[:relevant]
      distractors = fixture[:distractors] || []
      relevant_retrieved = (results & relevant).size
      distractor_retrieved = (results & distractors).size
      negative = relevant.empty?
      hit = negative ? results.empty? : relevant_retrieved.positive?
      {
        query: fixture[:query],
        results: results,
        negative: negative,
        hit: hit,
        relevant_retrieved: relevant_retrieved,
        relevant_total: relevant.size,
        distractor_retrieved: distractor_retrieved,
        distractor_total: distractors.size,
        contradiction: fixture[:contradiction] || false,
        label: hit ? "PASS" : "FAIL"
      }
    end

    def run_extraction(embedder)
      passed = 0
      Engram::EVAL_FIXTURES[:extraction_cases].each do |fixture|
        completion = completion_for(fixture[:response])
        extractor = Engram::Extractors::LLMExtractor.new(completion: completion, embedder: embedder)
        actual = extractor.extract(messages: fixture[:messages], scope: SCOPE).map(&:content)
        ok = live_completion? || actual == fixture[:expected]
        passed += 1 if ok
        puts "  #{ok ? "PASS" : "FAIL"}  #{fixture[:name]}"
        puts "        expected: #{fixture[:expected].join(" | ")}"
        puts "        actual:   #{actual.join(" | ")}"
      end
      puts format("  extraction cases: %.1f%% (%d/%d)", percent(passed, extraction_count), passed, extraction_count)
      passed == extraction_count
    end

    def run_consolidation(embedder)
      passed = 0
      Engram::EVAL_FIXTURES[:consolidation_cases].each do |fixture|
        store = Engram::Adapters::InMemoryStore.new
        fixture[:existing].each { |content| store.add(record(content, embedder)) }
        completion = completion_for(fixture[:response])
        consolidator = Engram::Consolidators::LLMConsolidator.new(store: store, completion: completion)
        decision = consolidator.reconcile_all(candidates: [record(fixture[:candidate], embedder)], scope: SCOPE).first
        ok = live_completion? || decision.action == fixture[:expected_action]
        passed += 1 if ok
        puts "  #{ok ? "PASS" : "FAIL"}  #{fixture[:name]} -> #{decision.action}"
      end
      puts format(
        "  consolidation cases: %.1f%% (%d/%d)",
        percent(passed, consolidation_count),
        passed,
        consolidation_count
      )
      passed == consolidation_count
    end

    def run_heuristic_consolidation(embedder)
      store = Engram::Adapters::InMemoryStore.new
      consolidator = Engram::Consolidators::HeuristicConsolidator.new(store: store)
      duplicate_fact = "User's subscription tier is Pro"
      novel_fact = "User lives in Berlin"
      store.add(record(duplicate_fact, embedder))

      duplicate_action = consolidator.reconcile_all(
        candidates: [record(duplicate_fact, embedder)],
        scope: SCOPE
      ).first.action
      novel_action = consolidator.reconcile_all(candidates: [record(novel_fact, embedder)], scope: SCOPE).first.action

      duplicate_adds = (duplicate_action == :add) ? 1 : 0
      puts "  #{duplicate_action == :noop ? "PASS" : "FAIL"}  duplicate fact -> #{duplicate_action}"
      puts "  #{novel_action == :add ? "PASS" : "FAIL"}  novel fact     -> #{novel_action}"
      puts format("  duplicate-add rate: %.1f%% (%d/1)", percent(duplicate_adds, 1), duplicate_adds)
      duplicate_action == :noop && novel_action == :add
    end

    def record(content, embedder)
      Engram::Record.new(content: content, scope: SCOPE, embedding: embedder.embed(content))
    end

    def completion_for(scripted_response)
      if live_completion?
        configure_ruby_llm!
        Engram::Adapters::RubyLLMCompletion.new(model: ENV["ENGRAM_COMPLETION_MODEL"])
      else
        Engram::Adapters::FakeCompletion.new(responses: [scripted_response])
      end
    end

    def live_completion?
      ENV["ENGRAM_COMPLETION"] == "ruby_llm"
    end

    def completion_mode
      live_completion? ? "live-adapter" : "scripted"
    end

    def null_embedder?(embedder)
      embedder.is_a?(Engram::Adapters::NullEmbedder)
    end

    def percent(numerator, denominator)
      return 0.0 if denominator.zero?

      100.0 * numerator / denominator
    end

    def extraction_count
      Engram::EVAL_FIXTURES[:extraction_cases].size
    end

    def consolidation_count
      Engram::EVAL_FIXTURES[:consolidation_cases].size
    end

    def warn_if_null_embedder(embedder)
      return unless null_embedder?(embedder)

      puts "NOTE: NullEmbedder is deterministic and non-semantic."
      puts "Recall metrics below are mechanics-only (n/a for semantic quality)."
      puts "Use ENGRAM_EMBEDDER=ruby_llm ENGRAM_EMBED_MODEL=text-embedding-3-small for honest recall numbers."
      puts
    end
  end
end
