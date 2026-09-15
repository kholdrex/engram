# frozen_string_literal: true

RSpec.describe Engram::UseCases::ForgetExpired do
  subject(:cleanup) { described_class.new(store: store) }

  let(:store) { Engram::Adapters::InMemoryStore.new }
  let(:now) { Time.utc(2026, 9, 15, 12) }

  def seed(expires_at: now, scope: "user:1")
    store.add(Engram::Record.new(content: "trial", scope: scope, expires_at: expires_at))
  end

  it "deletes every expired record in bounded pages without loading content or skipping rows" do
    5.times { seed }
    permanent = seed(expires_at: nil)
    future = seed(expires_at: now + 1)
    other = seed(scope: "user:2")
    expect(store).not_to receive(:all)
    expect(store).to receive(:expired_ids).with(scope: "user:1", at: now, limit: 2, after_id: nil).and_call_original
    expect(store).to receive(:expired_ids).with(scope: "user:1", at: now, limit: 2, after_id: 2).and_call_original
    expect(store).to receive(:expired_ids).with(scope: "user:1", at: now, limit: 2, after_id: 4).and_call_original
    expect(store).to receive(:expired_ids).with(scope: "user:1", at: now, limit: 2, after_id: 5).and_call_original

    expect(cleanup.call(scope: "user:1", batch_size: 2, now: now))
      .to eq(matched: 5, deleted: 5, dry_run: false)
    expect(store.existing_ids(scope: "user:1", ids: [permanent.id, future.id, other.id]))
      .to eq([permanent.id, future.id])
    expect(store.existing_ids(scope: "user:2", ids: [other.id])).to eq([other.id])
  end

  it "counts expired rows during a dry run without deleting them" do
    records = Array.new(3) { seed }
    seed(expires_at: nil)
    expect(store).not_to receive(:delete_expired)

    expect(cleanup.call(scope: "user:1", batch_size: 1, dry_run: true, now: now))
      .to eq(matched: 3, deleted: 0, dry_run: true)
    expect(store.existing_ids(scope: "user:1", ids: records.map(&:id))).to eq(records.map(&:id))
  end

  it "keeps a deadline extended after the batch was read and reports the actual deletion count" do
    extended = seed
    deleted = seed
    allow(store).to receive(:delete_expired).and_wrap_original do |original, **args|
      store.update(scope: "user:1", id: extended.id, record: extended.with(expires_at: now + 60))
      original.call(**args)
    end

    expect(cleanup.call(scope: "user:1", now: now)).to eq(matched: 2, deleted: 1, dry_run: false)
    expect(store.existing_ids(scope: "user:1", ids: [extended.id, deleted.id])).to eq([extended.id])
  end

  it "keeps one cutoff even when time advances between batches" do
    2.times { seed }
    future = seed(expires_at: now + 1)
    allow(Time).to receive(:now).and_return(now)
    allow(store).to receive(:delete_expired).and_wrap_original do |original, **args|
      allow(Time).to receive(:now).and_return(now + 60)
      original.call(**args)
    end

    expect(cleanup.call(scope: "user:1", batch_size: 1)).to eq(matched: 2, deleted: 2, dry_run: false)
    expect(store.existing_ids(scope: "user:1", ids: [future.id])).to eq([future.id])
  end

  it "can be retried after a batch fails" do
    3.times { seed }
    allow(store).to receive(:delete_expired).and_call_original
    allow(store).to receive(:delete_expired).with(scope: "user:1", ids: [2], at: now).and_raise("database unavailable")
    expect { cleanup.call(scope: "user:1", batch_size: 1, now: now) }.to raise_error("database unavailable")

    expect(cleanup.call(scope: "user:1", batch_size: 2, now: now)).to eq(matched: 2, deleted: 2, dry_run: false)
    expect(cleanup.call(scope: "user:1", now: now)).to eq(matched: 0, deleted: 0, dry_run: false)
  end

  it "rejects invalid options before reading or deleting records" do
    expect(store).not_to receive(:expired_ids)
    expect(store).not_to receive(:delete_expired)
    [0, -1, 1.5, "100", nil].each do |batch_size|
      expect { cleanup.call(scope: "user:1", batch_size: batch_size) }.to raise_error(ArgumentError, /batch_size/)
    end
    ["false", nil, 1].each do |dry_run|
      expect { cleanup.call(scope: "user:1", dry_run: dry_run) }.to raise_error(ArgumentError, /dry_run/)
    end
  end

  it "requires custom stores to implement conditional expiry deletion" do
    [Object.new, Class.new { include Engram::Ports::MemoryStore }.new].each do |legacy_store|
      expect { described_class.new(store: legacy_store).call(scope: "user:1") }
        .to raise_error(Engram::Error, /requires a store implementing expired_ids and delete_expired/)
    end
  end
end
