# frozen_string_literal: true

RSpec.describe Engram::Persistence do
  subject(:persistence) do
    described_class.new(
      store: Engram::Adapters::InMemoryStore.new,
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

    context "when the persistence policy returns false" do
      let(:policy) { ->(_) { false } }

      it "rejects authorization" do
        expect(persistence.allowed?(record)).to be(false)
      end
    end

    context "when the persistence policy returns nil" do
      let(:policy) { ->(_) {} }

      it "rejects authorization" do
        expect(persistence.allowed?(record)).to be(false)
      end
    end

    context "when the persistence policy returns a record" do
      let(:policy) { ->(candidate) { candidate } }

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
    end
  end
end
