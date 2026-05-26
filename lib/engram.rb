# frozen_string_literal: true

require_relative "engram/version"
require_relative "engram/configuration"
require_relative "engram/math"
require_relative "engram/memory_kind"
require_relative "engram/record"
require_relative "engram/decision"
require_relative "engram/turn_digest"
require_relative "engram/persistence_policy"
require_relative "engram/persistence"

# Ports (contracts)
require_relative "engram/ports/memory_store"
require_relative "engram/ports/embedder"
require_relative "engram/ports/completion"
require_relative "engram/ports/extractor"
require_relative "engram/ports/consolidator"
require_relative "engram/ports/processed_turns"

# Use cases
require_relative "engram/use_cases/recall"
require_relative "engram/use_cases/inject"
require_relative "engram/use_cases/observe"
require_relative "engram/use_cases/forget"

# Built-in adapters (pure Ruby, no external deps)
require_relative "engram/adapters/in_memory_store"
require_relative "engram/adapters/null_embedder"
require_relative "engram/adapters/fake_completion"
require_relative "engram/adapters/in_memory_processed_turns"

# Optional adapters. These reference external libraries (neighbor, ruby_llm) only at
# call time, so requiring the files here is safe even if those gems are absent.
require_relative "engram/adapters/pgvector_store"
require_relative "engram/adapters/ruby_llm_embedder"
require_relative "engram/adapters/ruby_llm_completion"

# Pipeline stages (v0.2)
require_relative "engram/extractors/llm_extractor"
require_relative "engram/consolidators/heuristic_consolidator"
require_relative "engram/consolidators/llm_consolidator"

require_relative "engram/memory"

# Optional integrations (pure Ruby; reference external libs only at call time)
require_relative "engram/integrations/ruby_llm"

# Public entrypoint and configuration store.
module Engram
  class Error < StandardError; end

  class << self
    def config
      @config ||= Configuration.new
    end

    def configure
      yield config
    end

    # Reset configuration (primarily for tests).
    def reset!
      @config = Configuration.new
    end
  end
end

require_relative "engram/railtie" if defined?(Rails::Railtie)
