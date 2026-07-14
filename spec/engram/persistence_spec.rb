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

  describe "#allowed?" do
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
    end
  end
end
