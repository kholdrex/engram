# frozen_string_literal: true

source "https://rubygems.org"

gemspec

group :development, :test do
  gem "rake", "~> 13.0"
  gem "rspec", "~> 3.13"
  gem "standard", "~> 1.3"
end

# Dependencies exercised only by the optional adapters and integration tests.
# Kept out of the gemspec so the core stays dependency-free.
group :integration do
  gem "activerecord", ">= 7.1"
  gem "pg", "~> 1.5"
  gem "neighbor", "~> 0.5"
end

# NOTE: ruby_llm is intentionally NOT a dependency here. The optional RubyLLM adapters and
# the real-embedder eval reference it only at call time; install it separately if you use them.
