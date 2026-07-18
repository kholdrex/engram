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

  def provenance(alignment: :exact, source_id: "message:1", source_type: "message",
    message_index: 0, role: "user", start_offset: 0, end_offset: 4,
    extractor_name: "host", model: "model-1", confidence: 0.9)
    Engram::Provenance.new(
      sources: [Engram::Provenance::Source.new(
        source_id: source_id, source_type: source_type, message_index: message_index, role: role,
        spans: [Engram::Provenance::Span.new(start_offset: start_offset, end_offset: end_offset)], alignment: alignment
      )],
      extractor: Engram::Provenance::Extractor.new(name: extractor_name, model: model), confidence: confidence
    )
  end

  def hostile_string_class
    Class.new(String) do
      class << self
        attr_accessor :hostile
      end

      def to_s = self.class.hostile ? raise("hostile to_s") : super
      def ==(other) = self.class.hostile ? raise("hostile ==") : super
      def eql?(other) = self.class.hostile ? raise("hostile eql?") : super
      def hash = self.class.hostile ? raise("hostile hash") : super
    end
  end

  def aliased_provenance(payload, outer_alias:, nested_alias:)
    string_class = hostile_string_class
    outer_key = string_class.new("_engram")
    nested_key = string_class.new("provenance")
    metadata = {
      (outer_alias ? outer_key : "_engram") => {
        (nested_alias ? nested_key : "provenance") => payload
      }
    }
    string_class.hostile = true
    metadata
  end

  def excessively_nested_provenance(container_type)
    nested = "leaf"
    101.times do
      nested = (container_type == :hash) ? {"nested" => nested} : [nested]
    end
    {"_engram" => {"provenance" => provenance.to_h.merge("extension" => nested)}}
  end

  def scope_with_hostile_equality(value)
    value = +value
    value.define_singleton_method(:==) { |_other| true }
    value
  end

  def json_serializing_store
    Class.new do
      attr_reader :serialized_metadata

      def add(record)
        @serialized_metadata = JSON.parse(JSON.generate(record.metadata))
        record
      end

      def update(scope:, id:, record:)
        @serialized_metadata = JSON.parse(JSON.generate(record.metadata))
        record
      end
    end.new
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

      it "rejects invalid-encoding provenance without mutating the store" do
        existing = store.add(Engram::Record.new(content: "Existing", scope: record.scope))
        original = store.all(scope: record.scope).map(&:to_h)
        payload = provenance.to_h
        payload.dig("sources", 0)["alignment"] = (+"ungrounded\xff").force_encoding("UTF-8")
        candidate = record.with(metadata: {"_engram" => {"provenance" => payload}})

        expect { persistence.add(candidate) }
          .to raise_error(Engram::Error, "malformed provenance: String values must have valid encoding")
        expect(store.all(scope: record.scope).map(&:to_h)).to eq(original)
        expect(store.all(scope: record.scope)).to eq([existing])
      end

      it "rejects invalid-encoding optional provenance before mutating the store" do
        existing = store.add(Engram::Record.new(content: "Existing", scope: record.scope))
        original = store.all(scope: record.scope).map(&:to_h)
        payload = provenance.to_h
        payload.fetch("extractor")["provider"] = (+"provider\xff").force_encoding("UTF-8")
        candidate = record.with(metadata: {"_engram" => {"provenance" => payload}})

        expect { persistence.add(candidate) }
          .to raise_error(Engram::Error, "malformed provenance: String values must have valid encoding")
        expect(store.all(scope: record.scope).map(&:to_h)).to eq(original)
        expect(store.all(scope: record.scope)).to eq([existing])
      end

      it "does not mutate the store when direct persistence receives excessively nested provenance" do
        existing = store.add(Engram::Record.new(content: "Existing", scope: record.scope))
        original = store.all(scope: record.scope).map(&:to_h)

        %i[hash array].each do |container_type|
          candidate = record.with(metadata: excessively_nested_provenance(container_type))

          expect { persistence.add(candidate) }
            .to raise_error(Engram::Error, /nesting exceeds maximum depth of 100/)
          expect(store.all(scope: record.scope).map(&:to_h)).to eq(original)
        end
        expect(store.all(scope: record.scope)).to eq([existing])
      end

      it "fails closed on invalid provenance hidden behind hostile String subclass aliases" do
        cases = [
          [aliased_provenance({"version" => 99}, outer_alias: true, nested_alias: false), /unsupported provenance version 99/],
          [aliased_provenance({"version" => 1, "sources" => []}, outer_alias: false, nested_alias: true), /malformed provenance/]
        ]
        cases.each do |metadata, error|
          expect { persistence.add(record.with(metadata: metadata)) }
            .to raise_error(Engram::Error, error)
        end
        expect(store.all(scope: record.scope)).to be_empty
      end

      it "does not let a behavior-bearing metadata Hash hide malformed provenance" do
        metadata_class = Class.new(Hash) do
          def key?(_key) = false
          def [](_key) = nil
          def select!(&_) = clear
          def reduce(initial, &_) = initial
        end
        metadata = metadata_class.new.update(future_provenance)

        expect { persistence.add(record.with(metadata: metadata)) }
          .to raise_error(Engram::Error, /unsupported provenance version 99/)
        expect(store.all(scope: record.scope)).to be_empty
      end

      it "does not let nested traversal overrides launder ungrounded provenance" do
        ungrounded = provenance(alignment: :ungrounded).to_h
        grounded_sources = provenance.to_h.fetch("sources")
        payload_class = Class.new(Hash) do
          define_method(:[]) do |key|
            if key == "sources"
              grounded_sources
            else
              super(key)
            end
          end
        end
        payload = payload_class.new.update(ungrounded)
        candidate = record.with(metadata: {"_engram" => {"provenance" => payload}})
        persistence = described_class.new(store: store, embedder: Engram::Adapters::NullEmbedder.new,
          persistence_policy: Engram::PersistencePolicy.new)

        expect(persistence.add(candidate)).to be_nil
        expect(store.all(scope: record.scope)).to be_empty
      end

      it "does not let nested each_pair overrides launder ungrounded provenance" do
        grounded_source = provenance.to_h.fetch("sources").first
        source_class = Class.new(Hash) do
          define_method(:each_pair) do |&block|
            return enum_for(:each_pair) unless block

            grounded_source.each_pair(&block)
          end
        end
        ungrounded_source = provenance(alignment: :ungrounded).to_h.fetch("sources").first
        ungrounded_source = source_class.new.update(ungrounded_source)
        payload = provenance.to_h.merge("sources" => [ungrounded_source])
        candidate = record.with(metadata: {"_engram" => {"provenance" => payload}})
        persistence = described_class.new(store: store, embedder: Engram::Adapters::NullEmbedder.new,
          persistence_policy: Engram::PersistencePolicy.new)

        expect(persistence.add(candidate)).to be_nil
        expect(store.all(scope: record.scope)).to be_empty
      end

      it "does not let a String subclass launder ungrounded provenance" do
        alignment_class = Class.new(String) do
          def to_sym = :exact
        end
        payload = provenance(alignment: :ungrounded).to_h
        payload.fetch("sources").first["alignment"] = alignment_class.new("ungrounded")
        candidate = record.with(metadata: {"_engram" => {"provenance" => payload}})
        persistence = described_class.new(store: store, embedder: Engram::Adapters::NullEmbedder.new,
          persistence_policy: Engram::PersistencePolicy.new)

        expect(persistence.add(candidate)).to be_nil
        expect(store.all(scope: record.scope)).to be_empty
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

    it "rejects a hostile scope introduced by before_persist" do
      hook = ->(candidate) { candidate.with(scope: scope_with_hostile_equality("u:victim")) }
      persistence = described_class.new(store: store, embedder: Engram::Adapters::NullEmbedder.new,
        before_persist: hook, persistence_policy: nil)

      expect { persistence.add(record) }
        .to raise_error(Engram::Error, "cannot move memory across scopes")
      expect(store.all(scope: record.scope)).to be_empty
      expect(store.all(scope: "u:victim")).to be_empty
    end

    it "rejects before_persist laundering ungrounded provenance as legacy metadata" do
      candidate = record.with(metadata: Engram::Provenance.attach({}, provenance(alignment: :ungrounded)))
      hook = ->(transformed) { transformed.with(metadata: {}) }
      persistence = described_class.new(store: store, embedder: Engram::Adapters::NullEmbedder.new,
        before_persist: hook, persistence_policy: Engram::PersistencePolicy.new)

      expect { persistence.add(candidate) }
        .to raise_error(Engram::Error, /before_persist cannot change provenance trust/)
      expect(store.all(scope: record.scope)).to be_empty
    end

    it "rejects before_persist downgrading grounded provenance to ungrounded" do
      grounded = record.with(metadata: Engram::Provenance.attach({}, provenance))
      ungrounded_metadata = Engram::Provenance.attach({}, provenance(alignment: :ungrounded))
      hook = ->(transformed) { transformed.with(metadata: ungrounded_metadata) }
      persistence = described_class.new(store: store, embedder: Engram::Adapters::NullEmbedder.new,
        before_persist: hook, persistence_policy: Engram::PersistencePolicy.new(allow_ungrounded: true))

      expect { persistence.add(grounded) }
        .to raise_error(Engram::Error, /before_persist cannot change provenance trust/)
      expect(store.all(scope: record.scope)).to be_empty
    end

    it "rejects before_persist rewriting any supporting provenance evidence" do
      grounded = record.with(metadata: Engram::Provenance.attach({}, provenance))
      mutations = [
        provenance(source_id: "message:other"), provenance(source_type: "document"),
        provenance(message_index: 1), provenance(role: "assistant"),
        provenance(start_offset: 1, end_offset: 5), provenance(alignment: :normalized),
        provenance(extractor_name: "other"), provenance(model: "model-2"), provenance(confidence: 0.8)
      ]

      mutations.each do |changed|
        hook = ->(transformed) { transformed.with(metadata: Engram::Provenance.attach({}, changed)) }
        guarded = described_class.new(store: store, embedder: Engram::Adapters::NullEmbedder.new,
          before_persist: hook, persistence_policy: nil)

        expect { guarded.add(grounded) }
          .to raise_error(Engram::Error, /before_persist cannot change provenance trust/)
      end
      expect(store.all(scope: record.scope)).to be_empty
    end

    it "rejects before_persist rewriting validated provenance extension evidence" do
      payload = provenance.to_h.merge(
        "evidence_digest" => "sha256:original",
        "extension" => {"nested" => ["one", 2, true]}
      )
      grounded = record.with(metadata: {"_engram" => {"provenance" => payload}})
      hook = lambda do |transformed|
        changed = payload.merge("evidence_digest" => "sha256:rewritten")
        transformed.with(metadata: {"_engram" => {"provenance" => changed}})
      end
      guarded = described_class.new(store: store, embedder: Engram::Adapters::NullEmbedder.new,
        before_persist: hook, persistence_policy: nil)

      expect { guarded.add(grounded) }
        .to raise_error(Engram::Error, /before_persist cannot change provenance trust/)
      expect(store.all(scope: record.scope)).to be_empty
    end

    it "rejects before_persist coercing integer confidence to an equal float" do
      payload = provenance(confidence: 1).to_h
      grounded = record.with(metadata: {"_engram" => {"provenance" => payload}})
      hook = lambda do |transformed|
        changed = payload.merge("confidence" => 1.0)
        transformed.with(metadata: {"_engram" => {"provenance" => changed}})
      end
      guarded = described_class.new(store: store, embedder: Engram::Adapters::NullEmbedder.new,
        before_persist: hook, persistence_policy: nil)

      expect { guarded.add(grounded) }
        .to raise_error(Engram::Error, /before_persist cannot change provenance trust/)
      expect(store.all(scope: record.scope)).to be_empty
    end

    it "rejects before_persist changing an extension's negative zero float bits" do
      payload = provenance.to_h.merge("extension" => {"signed_zero" => -0.0})
      grounded = record.with(metadata: {"_engram" => {"provenance" => payload}})
      hook = lambda do |transformed|
        changed = payload.merge("extension" => {"signed_zero" => 0.0})
        transformed.with(metadata: {"_engram" => {"provenance" => changed}})
      end
      guarded = described_class.new(store: store, embedder: Engram::Adapters::NullEmbedder.new,
        before_persist: hook, persistence_policy: nil)

      expect { guarded.add(grounded) }
        .to raise_error(Engram::Error, /before_persist cannot change provenance trust/)
      expect(store.all(scope: record.scope)).to be_empty
    end

    it "allows before_persist to preserve an exact integer and signed-zero payload" do
      payload = provenance(confidence: 1).to_h.merge("extension" => {"signed_zero" => -0.0})
      grounded = record.with(metadata: {"_engram" => {"provenance" => payload}})
      hook = lambda do |transformed|
        unchanged = payload.merge("extension" => {"signed_zero" => -0.0})
        transformed.with(content: "User likes [REDACTED]",
          metadata: {"_engram" => {"provenance" => unchanged}})
      end
      guarded = described_class.new(store: store, embedder: Engram::Adapters::NullEmbedder.new,
        before_persist: hook, persistence_policy: nil)

      persisted = guarded.add(grounded)

      expect(persisted.content).to eq("User likes [REDACTED]")
      expect(persisted.metadata.dig("_engram", "provenance")).to eq(payload)
    end

    it "allows content and embedding transforms when full extended provenance is unchanged" do
      payload = provenance.to_h.merge(
        "evidence_digest" => "sha256:original",
        "extension" => {"nested" => ["one", 2, true]}
      )
      grounded = record.with(embedding: [1.0], metadata: {"_engram" => {"provenance" => payload}})
      hook = ->(transformed) { transformed.with(content: "User likes [REDACTED]", embedding: [9.0]) }
      guarded = described_class.new(store: store, embedder: Engram::Adapters::NullEmbedder.new,
        before_persist: hook, persistence_policy: nil)

      persisted = guarded.add(grounded)

      expect(persisted.content).to eq("User likes [REDACTED]")
      expect(persisted.embedding).to eq(Engram::Adapters::NullEmbedder.new.embed(persisted.content))
      expect(persisted.metadata.dig("_engram", "provenance")).to eq(payload)
    end

    it "allows before_persist content redaction while preserving provenance" do
      grounded = record.with(metadata: Engram::Provenance.attach({}, provenance))
      hook = ->(transformed) { transformed.with(content: "User likes [REDACTED]") }
      persistence = described_class.new(store: store, embedder: Engram::Adapters::NullEmbedder.new,
        before_persist: hook, persistence_policy: Engram::PersistencePolicy.new)

      persisted = persistence.add(grounded)

      expect(persisted.content).to eq("User likes [REDACTED]")
      expect(Engram::Provenance.extract(persisted.metadata)).to eq(provenance)
    end
  end

  describe "prepared store boundary" do
    let(:policy) { nil }
    let(:store) { json_serializing_store }

    it "rejects a non-Hash reserved namespace before it can serialize forged provenance" do
      forged_reserved = Object.new
      forged_json = JSON.generate("provenance" => provenance.to_h.merge("version" => 99))
      forged_reserved.define_singleton_method(:to_json) { |*_args| forged_json }
      candidate = record.with(metadata: {"tenant" => "kept", "_engram" => forged_reserved})

      expect { persistence.add_prepared(candidate) }
        .to raise_error(Engram::Error, /metadata key "_engram" is reserved/)
      expect(store.serialized_metadata).to be_nil
    end

    it "hands updates the canonical plain provenance that was validated" do
      lying_string_class = Class.new(String) do
        def to_json(*_args) = JSON.generate("forged-extractor")
      end
      payload = provenance.to_h
      payload.fetch("extractor")["name"] = lying_string_class.new("host")
      metadata = {
        "tenant" => {"id" => 7},
        "_engram" => {
          "embedding" => {"dimensions" => 3, "model" => "embedder-v1"},
          "provenance" => payload
        }
      }
      candidate = record.with(metadata: metadata)

      persistence.update_prepared(scope: candidate.scope, id: 12, record: candidate)

      expect(store.serialized_metadata).to eq(
        "tenant" => {"id" => 7},
        "_engram" => {
          "embedding" => {"dimensions" => 3, "model" => "embedder-v1"},
          "provenance" => provenance.to_h
        }
      )
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

      it "fails closed on hostile String subclass aliases during direct updates" do
        original = stored_record.to_h

        cases = [
          [aliased_provenance({"version" => 99}, outer_alias: true, nested_alias: false), /unsupported provenance version 99/],
          [aliased_provenance({"version" => 1, "sources" => []}, outer_alias: false, nested_alias: true), /malformed provenance/]
        ]
        cases.each do |metadata, error|
          candidate = stored_record.with(content: "User likes coffee", metadata: metadata)
          expect {
            persistence.update(scope: candidate.scope, id: stored_record.id, record: candidate)
          }.to raise_error(Engram::Error, error)
        end
        expect(store.all(scope: stored_record.scope).map(&:to_h)).to eq([original])
      end

      it "does not let a Hash subclass hide malformed provenance on direct updates" do
        original = stored_record.to_h
        metadata_class = Class.new(Hash) do
          def key?(_key) = false
          def [](_key) = nil
        end
        candidate = stored_record.with(content: "User likes coffee",
          metadata: metadata_class.new.update(future_provenance))

        expect {
          persistence.update(scope: candidate.scope, id: stored_record.id, record: candidate)
        }.to raise_error(Engram::Error, /unsupported provenance version 99/)
        expect(store.all(scope: stored_record.scope).map(&:to_h)).to eq([original])
      end

      it "does not let a nested each_pair override hide future provenance on direct updates" do
        original = stored_record.to_h
        presented = provenance.to_h
        payload = provenance.to_h.merge("version" => 99)
        payload.define_singleton_method(:each_pair) do |&block|
          return enum_for(:each_pair) unless block

          presented.each_pair(&block)
        end
        candidate = stored_record.with(content: "User likes coffee",
          metadata: {"_engram" => {"provenance" => payload}})

        expect {
          persistence.update(scope: candidate.scope, id: stored_record.id, record: candidate)
        }.to raise_error(Engram::Error, /unsupported provenance version 99/)
        expect(store.all(scope: stored_record.scope).map(&:to_h)).to eq([original])
      end

      it "rejects before_persist removing grounded provenance without mutating the stored record" do
        original = stored_record.to_h
        candidate = stored_record.with(
          content: "User likes coffee",
          metadata: Engram::Provenance.attach({}, provenance)
        )
        hook = ->(transformed) { transformed.with(metadata: {}) }
        persistence = described_class.new(store: store, embedder: Engram::Adapters::NullEmbedder.new,
          before_persist: hook, persistence_policy: Engram::PersistencePolicy.new)

        expect {
          persistence.update(scope: candidate.scope, id: stored_record.id, record: candidate)
        }.to raise_error(Engram::Error, /before_persist cannot change provenance trust/)
        expect(store.all(scope: stored_record.scope).map(&:to_h)).to eq([original])
      end

      it "rejects a hostile scope introduced by before_persist without replacing a victim record" do
        victim = stored_record
        original = victim.to_h
        candidate = victim.with(content: "Attacker replacement")
        hook = ->(transformed) { transformed.with(scope: scope_with_hostile_equality("u:attacker")) }
        guarded = described_class.new(store: store, embedder: Engram::Adapters::NullEmbedder.new,
          before_persist: hook, persistence_policy: nil)

        expect {
          guarded.update(scope: victim.scope, id: victim.id, record: candidate)
        }.to raise_error(Engram::Error, "cannot move memory across scopes")
        expect(store.all(scope: victim.scope).map(&:to_h)).to eq([original])
        expect(store.all(scope: "u:attacker")).to be_empty
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
