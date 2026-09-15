# frozen_string_literal: true

# Loaded by the Railtie in Rails apps (where :environment boots the app and its
# initializers) and by the gem's own Rakefile (which defines a no-op :environment).
namespace :engram do
  desc "Delete expired memories in a scope. Usage: bundle exec rake 'engram:forget_expired[user:1]'"
  task :forget_expired, [:scope] => :environment do |_, args|
    scope = args[:scope]
    raise ArgumentError, "forget_expired requires a scope argument" if scope.to_s.empty?

    dry_run = case ENV.fetch("DRY_RUN", "false").downcase
    when "true", "1", "yes" then true
    when "false", "0", "no" then false
    else raise ArgumentError, "DRY_RUN must be true or false"
    end
    batch_size = Integer(ENV.fetch("BATCH_SIZE", "100"))
    result = Engram::Memory.new(scope: scope).forget_expired(batch_size: batch_size, dry_run: dry_run)
    puts "matched=#{result[:matched]} deleted=#{result[:deleted]} dry_run=#{result[:dry_run]}"
  end

  desc "Rebuild embeddings in a memory scope. Usage: bundle exec rake 'engram:rebuild_embeddings[user:1]'"
  task :rebuild_embeddings, [:scope] => :environment do |_, args|
    scope = args[:scope]
    raise ArgumentError, "rebuild_embeddings requires a scope argument" if scope.to_s.empty?

    stale_only = !%w[false 0 no].include?(ENV.fetch("STALE_ONLY", "true").downcase)
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
