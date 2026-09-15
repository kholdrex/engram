# frozen_string_literal: true

require "rake"

RSpec.describe "engram:forget_expired" do
  around do |example|
    original_application = Rake.application
    original_env = ENV.values_at("BATCH_SIZE", "DRY_RUN")
    ENV.delete("BATCH_SIZE")
    ENV.delete("DRY_RUN")
    Rake.application = Rake::Application.new
    Rake::Task.define_task(:environment)
    load File.expand_path("../../lib/engram/rails/tasks.rake", __dir__)
    example.run
  ensure
    Rake.application = original_application
    %w[BATCH_SIZE DRY_RUN].zip(original_env).each { |key, value| ENV[key] = value }
  end

  let(:task) { Rake::Task["engram:forget_expired"] }

  it "requires an explicit scope before accessing the store" do
    expect(Engram.config.store).not_to receive(:expired_ids)
    expect { task.invoke }.to raise_error(ArgumentError, /requires a scope/)
  end

  it "supports a dry run followed by deletion in the same scope" do
    store = Engram.config.store
    store.add(Engram::Record.new(content: "mine", scope: "user:1", expires_at: Time.now - 1))
    store.add(Engram::Record.new(content: "other", scope: "user:2", expires_at: Time.now - 1))
    ENV["BATCH_SIZE"] = "1"
    ENV["DRY_RUN"] = "true"
    expect { task.invoke("user:1") }.to output("matched=1 deleted=0 dry_run=true\n").to_stdout
    expect(store.all(scope: "user:1").length).to eq(1)

    ENV["DRY_RUN"] = "false"
    task.reenable
    expect { task.invoke("user:1") }.to output("matched=1 deleted=1 dry_run=false\n").to_stdout
    expect(store.all(scope: "user:1")).to eq([])
    expect(store.all(scope: "user:2").length).to eq(1)
  end

  it "rejects an invalid dry-run flag instead of deleting" do
    ENV["DRY_RUN"] = "treu"
    expect(Engram.config.store).not_to receive(:expired_ids)
    expect { task.invoke("user:1") }.to raise_error(ArgumentError, /DRY_RUN/)
  end

  it "rejects a nonpositive batch size instead of deleting" do
    ENV["BATCH_SIZE"] = "0"
    expect(Engram.config.store).not_to receive(:expired_ids)
    expect { task.invoke("user:1") }.to raise_error(ArgumentError, /batch_size/)
  end
end
