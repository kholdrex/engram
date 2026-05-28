# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

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

task default: %i[spec]
