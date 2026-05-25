# frozen_string_literal: true

require_relative "lib/engram/version"

Gem::Specification.new do |spec|
  spec.name = "engram"
  spec.version = Engram::VERSION
  spec.authors = ["Alexandr Kholodniak"]
  spec.email = ["alexandrkholodniak@gmail.com"]

  spec.summary = "Long-term memory for AI agents in Ruby — stored in your own Postgres."
  spec.description = <<~DESC
    Engram gives AI agents durable, long-term memory. It recalls relevant facts about a
    user and injects them into the prompt, so an agent appears to remember across sessions.
    Framework-agnostic core with a ports-and-adapters design; first-class Rails and RubyLLM
    integration. Your memories live in your own database — no external memory service.
  DESC
  spec.homepage = "https://github.com/kholdrex/engram"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.glob("lib/**/*.rb") + %w[README.md LICENSE.txt CHANGELOG.md]
  spec.require_paths = ["lib"]

  # NOTE: deliberately zero hard runtime dependencies — the pure core needs nothing.
  # Optional integrations require their own gems in the host app:
  #   * Engram::Adapters::PgvectorStore  => add `neighbor` and ActiveRecord
  #   * Engram::Adapters::RubyLLMEmbedder => add `ruby_llm`
end
