# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"
require_relative "lib/engram"

RSpec::Core::RakeTask.new(:spec)

begin
  require "standard/rake"
rescue LoadError
  # standard not installed; lint task unavailable
end

desc "Run the local Engram quality eval harness"
task :eval do
  ruby "eval/run.rb"
end

namespace :eval do
  desc "Run the eval harness against real RubyLLM providers (requires ruby_llm and provider configuration)"
  task :real do
    env = {
      "ENGRAM_EMBEDDER" => "ruby_llm",
      "ENGRAM_COMPLETION" => "ruby_llm"
    }
    Bundler.with_unbundled_env do
      sh(env, RbConfig.ruby, "eval/run.rb")
    end
  end
end

namespace :engram do
  desc "Rebuild embeddings in a memory scope. Usage: bundle exec rake 'engram:rebuild_embeddings[user:1]'"
  task :rebuild_embeddings, [:scope] do |_, args|
    scope = args[:scope]
    raise ArgumentError, "rebuild_embeddings requires a scope argument" if scope.to_s.empty?

    stale_only = ENV.fetch("STALE_ONLY", "true") != "false"
    batch_size = Integer(ENV.fetch("BATCH_SIZE", "100"))
    raise ArgumentError, "BATCH_SIZE must be greater than 0" unless batch_size.positive?

    result = Engram::UseCases::RebuildEmbeddings.new(
      store: Engram.config.store,
      embedder: Engram.config.embedder
    ).call(scope: scope, stale_only: stale_only, batch_size: batch_size)

    puts "scope=#{result[:scope]} processed=#{result[:processed]} updated=#{result[:updated]} skipped=#{result[:skipped]} failed=#{result[:failed]}"

    if result[:failed] > 0
      abort "failed_ids=#{result[:failed_ids].join(",")}"
    end
  end
end

task default: %i[spec]
