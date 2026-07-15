# frozen_string_literal: true

RSpec.describe Engram::Persistence do
  let(:store) { Engram::Adapters::InMemoryStore.new }

  subject(:persistence) do
    described_class.new(
      store: store,
      embedder: Engram::Adapters::NullEmbedder.new,
      persistence_policy: policy
    )
  end

  let(:record) { Engram::Record.new(content: "User likes tea", scope: "u:1") }
  let(:malformed_provenance) do
    {"_engram" => {"provenance" => {"version" => 1, "sources" => []}}}
  end
  let(:future_provenance) do
    {"_engram" => {"provenance" => {"version" => 99}}}
  end

  describe "#add" do
    context "without a persistence policy" do
      let(:policy) { nil }

      it "fails closed on malformed provenance" do
        candidate = record.with(metadata: malformed_provenance)

        expect { persistence.add(candidate) }.to raise_error(Engram::Error, /malformed provenance/)
      end

      it "fails closed on future provenance" do
        candidate = record.with(metadata: future_provenance)

        expect { persistence.add(candidate) }.to raise_error(Engram::Error, /unsupported provenance version 99/)
      end
    end

    context "with a custom persistence policy" do
      it "validates malformed input before a policy can replace it" do
        policy = instance_double(Proc)
        expect(policy).not_to receive(:call)
        persistence = described_class.new(store: store, embedder: Engram::Adapters::NullEmbedder.new,
          persistence_policy: policy)

        expect { persistence.add(record.with(metadata: malformed_provenance)) }
          .to raise_error(Engram::Error, /malformed provenance/)
      end

      it "fails closed when the policy returns malformed provenance" do
        policy = ->(candidate) { candidate.with(metadata: malformed_provenance) }
        persistence = described_class.new(
          store: Engram::Adapters::InMemoryStore.new,
          embedder: Engram::Adapters::NullEmbedder.new,
          persistence_policy: policy
        )

        expect { persistence.add(record) }.to raise_error(Engram::Error, /malformed provenance/)
      end

      it "fails closed when the policy introduces future provenance" do
        policy = ->(candidate) { candidate.with(metadata: future_provenance) }
        persistence = described_class.new(
          store: Engram::Adapters::InMemoryStore.new,
          embedder: Engram::Adapters::NullEmbedder.new,
          persistence_policy: policy
        )

        expect { persistence.add(record) }.to raise_error(Engram::Error, /unsupported provenance version 99/)
      end
    end

    it "validates future input before before_persist can strip it" do
      hook = instance_double(Proc)
      expect(hook).not_to receive(:call)
      persistence = described_class.new(store: store, embedder: Engram::Adapters::NullEmbedder.new,
        before_persist: hook, persistence_policy: nil)

      expect { persistence.add(record.with(metadata: future_provenance)) }
        .to raise_error(Engram::Error, /unsupported provenance version 99/)
    end

    it "validates provenance introduced by before_persist before policy can strip it" do
      hook = ->(candidate) { candidate.with(metadata: future_provenance) }
      policy = ->(candidate) { candidate.with(metadata: {}) }
      persistence = described_class.new(store: store, embedder: Engram::Adapters::NullEmbedder.new,
        before_persist: hook, persistence_policy: policy)

      expect { persistence.add(record) }
        .to raise_error(Engram::Error, /unsupported provenance version 99/)
      expect(store.all(scope: record.scope)).to be_empty
    end
  end

  describe "#update" do
    context "without a persistence policy" do
      let(:policy) { nil }
      let(:stored_record) { persistence.add(record.with(metadata: {"source" => "original"})) }

      it "fails closed on malformed provenance" do
        original = stored_record.to_h
        candidate = stored_record.with(content: "User likes coffee", metadata: malformed_provenance)

        expect {
          persistence.update(scope: candidate.scope, id: stored_record.id, record: candidate)
        }.to raise_error(Engram::Error, /malformed provenance/)
        expect(store.all(scope: stored_record.scope).map(&:to_h)).to eq([original])
      end

      it "fails closed on future provenance" do
        original = stored_record.to_h
        candidate = stored_record.with(content: "User likes coffee", metadata: future_provenance)

        expect {
          persistence.update(scope: candidate.scope, id: stored_record.id, record: candidate)
        }.to raise_error(Engram::Error, /unsupported provenance version 99/)
        expect(store.all(scope: stored_record.scope).map(&:to_h)).to eq([original])
      end
    end
  end

  describe "#allowed?" do
    context "without a persistence policy" do
      let(:policy) { nil }

      it "fails closed on malformed provenance" do
        candidate = record.with(metadata: malformed_provenance)

        expect { persistence.allowed?(candidate) }.to raise_error(Engram::Error, /malformed provenance/)
      end

      it "fails closed on future provenance" do
        candidate = record.with(metadata: future_provenance)

        expect { persistence.allowed?(candidate) }.to raise_error(Engram::Error, /unsupported provenance version 99/)
      end
    end

    context "when a policy explicitly denies destructive authorization" do
      let(:policy) do
        Class.new do
          def call(record) = record
          def allow_destructive?(_) = false
        end.new
      end

      it "rejects authorization" do
        expect(persistence.allowed?(record)).to be(false)
      end
    end

    context "when a custom write policy has no destructive authorization contract" do
      let(:policy) { ->(_) {} }

      it "does not conflate write rejection with destructive authorization" do
        expect(persistence.allowed?(record)).to be(true)
      end
    end

    context "when a policy explicitly allows destructive authorization" do
      let(:policy) do
        Class.new do
          def call(record) = record
          def allow_destructive?(_) = true
        end.new
      end

      it "allows authorization" do
        expect(persistence.allowed?(record)).to be(true)
      end

      it "fails closed on malformed provenance" do
        candidate = record.with(metadata: malformed_provenance)

        expect { persistence.allowed?(candidate) }.to raise_error(Engram::Error, /malformed provenance/)
      end

      it "fails closed on future provenance" do
        candidate = record.with(metadata: future_provenance)

        expect { persistence.allowed?(candidate) }.to raise_error(Engram::Error, /unsupported provenance version 99/)
      end

      it "validates malformed authorization input before the policy can replace it" do
        policy = instance_double(Proc)
        expect(policy).not_to receive(:call)
        persistence = described_class.new(store: store, embedder: Engram::Adapters::NullEmbedder.new,
          persistence_policy: policy)

        expect { persistence.allowed?(record.with(metadata: malformed_provenance)) }
          .to raise_error(Engram::Error, /malformed provenance/)
      end
    end

    it "rejects malformed destructive policy returns with a stable Engram error" do
      policy = Class.new do
        def call(record) = record
        def allow_destructive?(_) = {allowed: true}
      end.new
      persistence = described_class.new(store: store, embedder: Engram::Adapters::NullEmbedder.new,
        persistence_policy: policy)

      expect { persistence.allowed?(record) }
        .to raise_error(Engram::Error, "persistence policy allow_destructive? must return true or false")
    end
  end
end
