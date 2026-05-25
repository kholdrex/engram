# frozen_string_literal: true

require "engram"

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed

  # Integration specs (real Postgres + pgvector) are opt-in: run with `--tag integration`.
  config.filter_run_excluding :integration

  # Each example starts from a clean configuration.
  config.before { Engram.reset! }
end
