# frozen_string_literal: true

RSpec.describe Engram::UseCases::Observe do
  let(:store) { Engram::Adapters::InMemoryStore.new }
  let(:embedder) { Engram::Adapters::NullEmbedder.new }

  def extraction(*facts)
    {"facts" => facts.map { |f| {"content" => f, "confidence" => 0.9} }}
  end

  def extractor_for(completion)
    Engram::Extractors::LLMExtractor.new(completion: completion, embedder: embedder)
  end

  def provenance(alignment: :exact)
    Engram::Provenance.new(
      sources: [Engram::Provenance::Source.new(
        source_id: "message:1", source_type: "message", message_index: 0, role: "user",
        spans: [Engram::Provenance::Span.new(start_offset: 0, end_offset: 4)], alignment: alignment
      )],
      extractor: Engram::Provenance::Extractor.new(name: "host", model: "model-1"), confidence: 0.9
    )
  end

  it "normalizes Record and Extraction array members before consolidation" do
    plain = Engram::Record.new(content: "Plain", scope: "u:1", embedding: [0.0])
    wrapped_record = Engram::Record.new(content: "Grounded", scope: "u:1", embedding: [0.0],
      metadata: {"host" => true})
    extraction = Engram::Extraction.new(record: wrapped_record, provenance: provenance)
    extractor = double(extract: [plain, extraction])
    consolidator = double
    expect(consolidator).to receive(:reconcile_all) do |candidates:, scope:|
      expect(scope).to eq("u:1")
      expect(candidates).to all(be_a(Engram::Record))
      expect(candidates.first).to equal(plain)
      expect(Engram::Provenance.extract(candidates.last.metadata)).to eq(provenance)
      expect(candidates.last.metadata).to include("host" => true)
      []
    end

    described_class.new(store: store, extractor: extractor, consolidator: consolidator)
      .call(messages: ["turn"], scope: "u:1")
  end

  it "preserves arbitrary application metadata from custom extractors" do
    value_class = Struct.new(:account_id)
    object = Object.new
    value_object = value_class.new(42)
    extracted = Engram::Record.new(content: "Custom candidate", scope: "u:1", embedding: [0.0],
      metadata: {"object" => object, "value_object" => value_object})
    consolidator = double
    expect(consolidator).to receive(:reconcile_all) do |candidates:, **|
      [Engram::Decision.new(action: :add, candidate: candidates.first)]
    end

    described_class.new(store: store, extractor: double(extract: [extracted]),
      consolidator: consolidator, embedder: embedder).call(messages: ["turn"], scope: "u:1")

    persisted = store.all(scope: "u:1").first
    expect(persisted.metadata.fetch("object")).to equal(object)
    expect(persisted.metadata.fetch("value_object")).to equal(value_object)
  end

  it "normalizes Record subclasses to plain records before candidate integrity checks" do
    record_class = Class.new(Engram::Record) do
      def id
        raise "subclass reader must not be invoked"
      end
    end
    extracted = record_class.new(content: "Subclass candidate", scope: "u:1", embedding: [0.0])
    consolidator = double
    expect(consolidator).to receive(:reconcile_all) do |candidates:, scope:|
      expect(candidates.first).to be_instance_of(Engram::Record)
      [Engram::Decision.new(action: :add, candidate: candidates.first)]
    end

    applied = described_class.new(store: store, extractor: double(extract: [extracted]),
      consolidator: consolidator, embedder: embedder)
      .call(messages: ["turn"], scope: "u:1")

    expect(applied.map(&:action)).to eq([:add])
    expect(store.all(scope: "u:1").map(&:content)).to eq(["Subclass candidate"])
  end

  it "rejects default-proc metadata while normalizing Record subclasses" do
    record_class = Class.new(Engram::Record)
    metadata = Hash.new { |_hash, key| "generated:#{key}" }
    extracted = record_class.new(content: "Subclass candidate", scope: "u:1", embedding: [0.0], metadata: metadata)
    consolidator = double
    expect(consolidator).not_to receive(:reconcile_all)

    expect do
      described_class.new(store: store, extractor: double(extract: [extracted]),
        consolidator: consolidator, embedder: embedder)
        .call(messages: ["turn"], scope: "u:1")
    end.to raise_error(Engram::Error, /Hash with a default proc/)

    expect(store.all(scope: "u:1")).to be_empty
  end

  it "rejects singleton Record behavior without invoking an overridden id reader" do
    extracted = Engram::Record.new(content: "Singleton candidate", scope: "u:1", embedding: [0.0])
    id_calls = 0
    extracted.define_singleton_method(:id) do
      id_calls += 1
      raise "singleton reader must not be invoked"
    end
    consolidator = double
    expect(consolidator).not_to receive(:reconcile_all)

    expect do
      described_class.new(store: store, extractor: double(extract: [extracted]),
        consolidator: consolidator, embedder: embedder)
        .call(messages: ["turn"], scope: "u:1")
    end.to raise_error(Engram::Error, /plain Engram::Record/)

    expect(id_calls).to eq(0)
    expect(store.all(scope: "u:1")).to be_empty
  end

  it "validates an Extraction subclass result before invoking a Record reader" do
    behavior_bearing = Engram::Record.new(content: "Behavior-bearing candidate", scope: "u:1", embedding: [0.0])
    id_calls = 0
    behavior_bearing.define_singleton_method(:id) do
      id_calls += 1
      raise "singleton reader must not be invoked"
    end
    extraction_class = Class.new(Engram::Extraction) do
      define_method(:to_record) { behavior_bearing }
    end
    extracted = extraction_class.new(
      record: Engram::Record.new(content: "Original", scope: "u:1", embedding: [0.0]),
      provenance: provenance
    )
    consolidator = double
    expect(consolidator).not_to receive(:reconcile_all)

    expect do
      described_class.new(store: store, extractor: double(extract: [extracted]),
        consolidator: consolidator, embedder: embedder)
        .call(messages: ["turn"], scope: "u:1")
    end.to raise_error(Engram::Error, /plain Engram::Record/)

    expect(id_calls).to eq(0)
    expect(store.all(scope: "u:1")).to be_empty
  end

  it "rejects invalid extractor containers and members before consolidation or store mutation" do
    valid = Engram::Record.new(content: "Candidate", scope: "u:1", embedding: [0.0])
    invalid_outputs = [nil, valid, [valid].each, [Object.new], [valid, nil]]

    invalid_outputs.each do |output|
      extractor = double(extract: output)
      consolidator = double
      expect(consolidator).not_to receive(:reconcile_all)

      expect do
        described_class.new(store: store, extractor: extractor, consolidator: consolidator)
          .call(messages: ["turn"], scope: "u:1")
      end.to raise_error(Engram::Error, /extractor must return an Array containing only/)
      expect(store.all(scope: "u:1")).to be_empty
    end
  end

  it "rejects a non-Array extractor result that overrides is_a? with a stable Engram error" do
    output = Object.new
    output.define_singleton_method(:is_a?) { |klass| klass.equal?(Array) || super(klass) }
    consolidator = double
    expect(consolidator).not_to receive(:reconcile_all)

    expect do
      described_class.new(store: store, extractor: double(extract: output), consolidator: consolidator)
        .call(messages: ["turn"], scope: "u:1")
    end.to raise_error(Engram::Error, /extractor must return an Array containing only/)
    expect(store.all(scope: "u:1")).to be_empty
  end

  it "does not let Array map overrides skip extractor member normalization" do
    subclass = Class.new(Array) do
      def map(&_) = []
    end
    containers = [subclass.new([Object.new]), [Object.new]]
    containers.last.define_singleton_method(:map) { |&_| [] }

    containers.each do |output|
      consolidator = double
      expect(consolidator).not_to receive(:reconcile_all)

      expect do
        described_class.new(store: store, extractor: double(extract: output), consolidator: consolidator)
          .call(messages: ["turn"], scope: "u:1")
      end.to raise_error(Engram::Error, /extractor must return an Array containing only/)
    end
  end

  it "does not let Array map overrides skip decision validation and canonicalization" do
    candidate = Engram::Record.new(content: "Candidate", scope: "u:1", embedding: [0.0])
    subclass = Class.new(Array) do
      def map(&_) = []
    end
    containers = [subclass.new([Object.new]), [Object.new]]
    containers.last.define_singleton_method(:map) { |&_| [] }

    containers.each do |output|
      observe = described_class.new(store: store, extractor: double(extract: [candidate]),
        consolidator: double(reconcile_all: output), embedder: embedder)

      expect { observe.call(messages: ["turn"], scope: "u:1") }
        .to raise_error(Engram::Error, /consolidator must return an Array of Engram::Decision/)
      expect(store.all(scope: "u:1")).to be_empty
    end
  end

  it "rejects a non-Array consolidator result that overrides is_a? with a stable Engram error" do
    candidate = Engram::Record.new(content: "Candidate", scope: "u:1", embedding: [0.0])
    output = Object.new
    output.define_singleton_method(:is_a?) { |klass| klass.equal?(Array) || super(klass) }
    observe = described_class.new(store: store, extractor: double(extract: [candidate]),
      consolidator: double(reconcile_all: output), embedder: embedder)

    expect { observe.call(messages: ["turn"], scope: "u:1") }
      .to raise_error(Engram::Error, /consolidator must return an Array of Engram::Decision/)
    expect(store.all(scope: "u:1")).to be_empty
  end

  it "rejects a forged decision member that overrides is_a? before store mutation" do
    candidate = Engram::Record.new(content: "Candidate", scope: "u:1", embedding: [0.0])
    forged = Object.new
    forged.define_singleton_method(:is_a?) { |klass| klass.equal?(Engram::Decision) || super(klass) }
    forged.define_singleton_method(:action) { :add }
    forged.define_singleton_method(:candidate) { candidate }
    forged.define_singleton_method(:target_id) { nil }
    forged.define_singleton_method(:reason) { "forged" }
    observe = described_class.new(store: store, extractor: double(extract: [candidate]),
      consolidator: double(reconcile_all: [forged]), embedder: embedder)

    expect { observe.call(messages: ["turn"], scope: "u:1") }
      .to raise_error(Engram::Error, "consolidator must return an Array of Engram::Decision values")
    expect(store.all(scope: "u:1")).to be_empty
  end

  it "does not let Array map overrides bypass target ID canonicalization" do
    candidate = Engram::Record.new(content: "Replacement", scope: "u:1", embedding: [0.0])
    expect(store).not_to receive(:update)

    2.times do |index|
      target_id = +"victim"
      target_id.define_singleton_method(:to_s) { "behavior-bearing" }
      decision = Engram::Decision.new(action: :update, candidate: candidate, target_id: target_id)
      output = if index.zero?
        Class.new(Array) { define_method(:map) { |&_| [decision] } }.new([decision])
      else
        [decision].tap { |values| values.define_singleton_method(:map) { |&_| [decision] } }
      end
      observe = described_class.new(store: store, extractor: double(extract: [candidate]),
        consolidator: double(reconcile_all: output), embedder: embedder)

      expect { observe.call(messages: ["turn"], scope: "u:1") }
        .to raise_error(Engram::Error, "decision target_id must be a plain String or Integer")
      expect(store.all(scope: "u:1")).to be_empty
    end
  end

  it "rejects extracted add candidates with supplied IDs before they can overwrite scoped records" do
    victims = [
      store.add(Engram::Record.new(content: "Same scope", scope: "u:1", embedding: [0.0])),
      store.add(Engram::Record.new(content: "Other scope", scope: "u:2", embedding: [0.0]))
    ]

    victims.each do |victim|
      candidate = Engram::Record.new(id: victim.id, content: "Overwrite", scope: "u:1", embedding: [0.0])
      extractor = double(extract: [candidate])
      consolidator = double
      expect(consolidator).not_to receive(:reconcile_all)

      expect do
        described_class.new(store: store, extractor: extractor, consolidator: consolidator, embedder: embedder)
          .call(messages: ["turn"], scope: "u:1")
      end.to raise_error(Engram::Error, "observation candidates must not have an id")
    end

    expect(store.all(scope: "u:1").map(&:content)).to eq(["Same scope"])
    expect(store.all(scope: "u:2").map(&:content)).to eq(["Other scope"])
  end

  it "releases its claim when extractor output validation fails" do
    outputs = [nil, []]
    extractor = Object.new
    extractor.define_singleton_method(:extract) { |messages:, scope:| outputs.shift }
    processed = Engram::Adapters::InMemoryProcessedTurns.new
    observe = described_class.new(store: store, extractor: extractor,
      consolidator: double(reconcile_all: []), processed_turns: processed)

    expect { observe.call(messages: ["turn"], scope: "u:1", idempotency_key: "turn-1") }
      .to raise_error(Engram::Error)
    expect(observe.call(messages: ["turn"], scope: "u:1", idempotency_key: "turn-1")).to eq([])
  end

  it "accepts noop decisions with malformed or future provenance and completes their claims" do
    metadata_values = [
      {"_engram" => {"provenance" => {"version" => 1, "sources" => []}}},
      {"_engram" => {"provenance" => {"version" => 99}}}
    ]

    metadata_values.each_with_index do |metadata, index|
      candidate = Engram::Record.new(content: "Candidate", scope: "u:1", embedding: [0.0], metadata: metadata)
      extractor = double(extract: [candidate])
      decision = Engram::Decision.new(action: :noop, candidate: candidate)
      processed = Engram::Adapters::InMemoryProcessedTurns.new
      observe = described_class.new(store: store, extractor: extractor,
        consolidator: double(reconcile_all: [decision]), processed_turns: processed, embedder: embedder)
      key = "noop-#{index}"

      expect(observe.call(messages: ["turn"], scope: "u:1", idempotency_key: key)).to eq([])
      expect(observe.call(messages: ["turn"], scope: "u:1", idempotency_key: key)).to eq([])
      expect(extractor).to have_received(:extract).once
    end
  end

  it "rejects opaque-container provenance mutation before destructive authorization" do
    target = store.add(Engram::Record.new(content: "Old", scope: "u:1", embedding: [0.0]))
    metadata = Engram::Provenance.attach({}, provenance)
    opaque_reserved = Class.new(Hash).new
    opaque_reserved.replace(metadata.fetch("_engram"))
    metadata["_engram"] = opaque_reserved
    candidate = Engram::Record.new(content: "Correction", scope: "u:1", embedding: [0.0], metadata: metadata)
    policy = double
    expect(policy).not_to receive(:allow_destructive?)
    Engram.config.persistence_policy = policy
    consolidator = double
    expect(consolidator).to receive(:reconcile_all) do |candidates:, **|
      opaque_reserved.fetch("provenance").fetch("sources").first["source_id"] = "message:other"
      [Engram::Decision.new(action: :forget, candidate: candidates.first, target_id: target.id)]
    end
    observe = described_class.new(store: store, extractor: double(extract: [candidate]),
      consolidator: consolidator, embedder: embedder)

    expect { observe.call(messages: ["turn"], scope: "u:1") }
      .to raise_error(Engram::Error, /consolidators must not mutate candidates/)
    expect(store.all(scope: "u:1")).to eq([target])
  end

  it "validates only a forget decision's candidate without invoking write hooks" do
    malformed_target = store.add(Engram::Record.new(content: "Old", scope: "u:1", embedding: [0.0],
      metadata: {"_engram" => {"provenance" => {"version" => 99}}}))
    candidate = Engram::Record.new(content: "Correction", scope: "u:1", embedding: [0.0],
      metadata: Engram::Provenance.attach({}, provenance))
    hook_calls = 0
    Engram.config.before_persist = lambda do |record|
      hook_calls += 1
      record
    end
    decision = Engram::Decision.new(action: :forget, candidate: candidate, target_id: malformed_target.id)

    applied = described_class.new(store: store, extractor: double(extract: [candidate]),
      consolidator: double(reconcile_all: [decision]), embedder: embedder)
      .call(messages: ["turn"], scope: "u:1")

    expect(applied.map(&:action)).to eq([:forget])
    expect(applied.first.candidate).to equal(candidate)
    expect(hook_calls).to eq(0)
    expect(store.all(scope: "u:1")).to be_empty
  end

  it "drops a whole forget decision when candidate provenance is ungrounded" do
    target = store.add(Engram::Record.new(content: "Old", scope: "u:1", embedding: [0.0]))
    candidate = Engram::Record.new(content: "Correction", scope: "u:1", embedding: [0.0],
      metadata: Engram::Provenance.attach({}, provenance(alignment: :ungrounded)))
    decision = Engram::Decision.new(action: :forget, candidate: candidate, target_id: target.id)

    applied = described_class.new(store: store, extractor: double(extract: [candidate]),
      consolidator: double(reconcile_all: [decision]), embedder: embedder)
      .call(messages: ["turn"], scope: "u:1")

    expect(applied).to be_empty
    expect(store.all(scope: "u:1")).to eq([target])
  end

  it "authorizes forget independently of write-content filtering and redaction" do
    candidate_contents = [
      "API key is abcdefgh_123",
      "The migration was completed today",
      "Remove internal-ticket-123"
    ]
    Engram.config.persistence_policy = Engram::PersistencePolicy.new(
      denylist_patterns: [/internal-ticket-\d+/i]
    )

    candidate_contents.each do |content|
      target = store.add(Engram::Record.new(content: content, scope: "u:1", embedding: [0.0]))
      candidate = Engram::Record.new(content: content, scope: "u:1", embedding: [0.0])
      decision = Engram::Decision.new(action: :forget, candidate: candidate, target_id: target.id)

      applied = described_class.new(store: store, extractor: double(extract: [candidate]),
        consolidator: double(reconcile_all: [decision]), embedder: embedder)
        .call(messages: ["turn"], scope: "u:1")

      expect(applied.map(&:action)).to eq([:forget])
      expect(store.all(scope: "u:1")).to be_empty
    end
  end

  it "does not use a custom write-only policy to authorize forget" do
    Engram.config.persistence_policy = ->(_) {}
    target = store.add(Engram::Record.new(content: "Old", scope: "u:1", embedding: [0.0]))
    candidate = Engram::Record.new(content: "Correction", scope: "u:1", embedding: [0.0])
    decision = Engram::Decision.new(action: :forget, candidate: candidate, target_id: target.id)

    applied = described_class.new(store: store, extractor: double(extract: [candidate]),
      consolidator: double(reconcile_all: [decision]), embedder: embedder)
      .call(messages: ["turn"], scope: "u:1")

    expect(applied.map(&:action)).to eq([:forget])
    expect(store.all(scope: "u:1")).to be_empty
  end

  it "rejects a forget decision without a Record candidate before deleting" do
    target = store.add(Engram::Record.new(content: "Old", scope: "u:1", embedding: [0.0]))
    extracted = Engram::Record.new(content: "Correction", scope: "u:1", embedding: [0.0])
    decision = Engram::Decision.new(action: :forget, candidate: nil, target_id: target.id)
    observe = described_class.new(store: store, extractor: double(extract: [extracted]),
      consolidator: double(reconcile_all: [decision]), embedder: embedder)

    expect { observe.call(messages: ["turn"], scope: "u:1") }
      .to raise_error(Engram::Error, "forget decision candidate must be an Engram::Record")
    expect(store.all(scope: "u:1")).to eq([target])
  end

  it "rejects a forget decision whose candidate is outside the call scope" do
    target = store.add(Engram::Record.new(content: "Private", scope: "u:1", embedding: [0.0]))
    candidate = Engram::Record.new(content: "Attack", scope: "u:2", embedding: [0.0])
    decision = Engram::Decision.new(action: :forget, candidate: candidate, target_id: target.id)
    observe = described_class.new(store: store, extractor: double(extract: [candidate]),
      consolidator: double(reconcile_all: [decision]), embedder: embedder)

    expect { observe.call(messages: ["attack"], scope: "u:1") }
      .to raise_error(Engram::Error, "cannot move memory across scopes")
    expect(store.all(scope: "u:1")).to eq([target])
  end

  it "rejects behavior-bearing candidate scope before reconciliation" do
    target = store.add(Engram::Record.new(content: "Private", scope: "u:1", embedding: [0.0]))
    hostile_scope = Object.new
    hostile_scope.define_singleton_method(:==) { |_other| true }
    candidate = Engram::Record.new(content: "Attack", scope: hostile_scope, embedding: [0.0])
    consolidator = double
    expect(consolidator).not_to receive(:reconcile_all)

    expect do
      described_class.new(store: store, extractor: double(extract: [candidate]),
        consolidator: consolidator, embedder: embedder)
        .call(messages: ["attack"], scope: "u:1")
    end.to raise_error(Engram::Error, /scope/)

    expect(store.all(scope: "u:1")).to eq([target])
  end

  it "rejects a forged same-scope candidate returned by a custom consolidator" do
    target = store.add(Engram::Record.new(content: "Private", scope: "u:1", embedding: [0.0]))
    extracted = Engram::Record.new(content: "Correction", scope: "u:1", embedding: [0.0])
    forged = extracted.with(content: "Forged authorization")
    decision = Engram::Decision.new(action: :forget, candidate: forged, target_id: target.id)
    observe = described_class.new(store: store, extractor: double(extract: [extracted]),
      consolidator: double(reconcile_all: [decision]), embedder: embedder)

    expect { observe.call(messages: ["turn"], scope: "u:1") }
      .to raise_error(Engram::Error, /candidate supplied to the consolidator/)
    expect(store.all(scope: "u:1")).to eq([target])
  end

  it "rejects two forget decisions for the same candidate before deleting either target" do
    targets = ["First", "Second"].map do |content|
      store.add(Engram::Record.new(content: content, scope: "u:1", embedding: [0.0]))
    end
    candidate = Engram::Record.new(content: "Correction", scope: "u:1", embedding: [0.0])
    decisions = targets.map do |target|
      Engram::Decision.new(action: :forget, candidate: candidate, target_id: target.id)
    end
    observe = described_class.new(store: store, extractor: double(extract: [candidate]),
      consolidator: double(reconcile_all: decisions), embedder: embedder)

    expect { observe.call(messages: ["turn"], scope: "u:1") }
      .to raise_error(Engram::Error, /multiple decisions reference the same candidate/)
    expect(store.all(scope: "u:1")).to match_array(targets)
  end

  it "rejects duplicate and mixed decisions for one candidate before any mutation" do
    [
      %i[add add],
      %i[add noop]
    ].each do |actions|
      candidate = Engram::Record.new(content: "Candidate", scope: "u:1", embedding: [0.0])
      decisions = actions.map { |action| Engram::Decision.new(action: action, candidate: candidate) }
      observe = described_class.new(store: store, extractor: double(extract: [candidate]),
        consolidator: double(reconcile_all: decisions), embedder: embedder)

      expect { observe.call(messages: ["turn"], scope: "u:1") }
        .to raise_error(Engram::Error, /multiple decisions reference the same candidate/)
      expect(store.all(scope: "u:1")).to be_empty
    end
  end

  it "allows one decision per occurrence when extraction repeats the same candidate instance" do
    candidate = Engram::Record.new(content: "Candidate", scope: "u:1", embedding: [0.0])
    decisions = [
      Engram::Decision.new(action: :add, candidate: candidate),
      Engram::Decision.new(action: :noop, candidate: candidate)
    ]
    observe = described_class.new(store: store, extractor: double(extract: [candidate, candidate]),
      consolidator: double(reconcile_all: decisions), embedder: embedder)

    applied = observe.call(messages: ["turn"], scope: "u:1")
    expect(applied.map(&:action)).to eq([:add])
    expect(applied.first.candidate).to equal(candidate)
    expect(store.all(scope: "u:1").map(&:content)).to eq(["Candidate"])
  end

  it "rejects a consolidator that clears candidate metadata before authorizing deletion" do
    target = store.add(Engram::Record.new(content: "Old", scope: "u:1", embedding: [0.0]))
    candidate = Engram::Record.new(content: "Ungrounded correction", scope: "u:1", embedding: [0.0],
      metadata: Engram::Provenance.attach({}, provenance(alignment: :ungrounded)))
    consolidator = Object.new
    consolidator.define_singleton_method(:reconcile_all) do |candidates:, scope:|
      candidates.first.metadata.clear
      [Engram::Decision.new(action: :forget, candidate: candidates.first, target_id: target.id)]
    end
    observe = described_class.new(store: store, extractor: double(extract: [candidate]),
      consolidator: consolidator, embedder: embedder)

    expect { observe.call(messages: ["turn"], scope: "u:1") }
      .to raise_error(Engram::Error, /must not mutate candidates/)
    expect(store.all(scope: "u:1")).to eq([target])
  end

  it "rejects candidates collection mutation before authorizing deletion" do
    mutations = [
      ->(candidates) { candidates << candidates.first },
      ->(candidates) { candidates.reverse! },
      ->(candidates) { candidates.define_singleton_method(:each) { |_block| [] } }
    ]

    mutations.each do |mutation|
      target = store.add(Engram::Record.new(content: "Old", scope: "u:1", embedding: [0.0]))
      candidates = [
        Engram::Record.new(content: "First", scope: "u:1", embedding: [0.0]),
        Engram::Record.new(content: "Second", scope: "u:1", embedding: [0.0])
      ]
      consolidator = Object.new
      consolidator.define_singleton_method(:reconcile_all) do |candidates:, scope:|
        decision_candidate = candidates.first
        mutation.call(candidates)
        [Engram::Decision.new(action: :forget, candidate: decision_candidate, target_id: target.id)]
      end

      expect do
        described_class.new(store: store, extractor: double(extract: candidates),
          consolidator: consolidator, embedder: embedder)
          .call(messages: ["turn"], scope: "u:1")
      end.to raise_error(Engram::Error, /must not mutate the candidates collection/)
      expect(store.all(scope: "u:1")).to eq([target])
      store.clear
    end
  end

  it "rejects nested provenance mutation by a custom consolidator" do
    target = store.add(Engram::Record.new(content: "Old", scope: "u:1", embedding: [0.0]))
    candidate = Engram::Record.new(content: "Ungrounded correction", scope: "u:1", embedding: [0.0],
      metadata: Engram::Provenance.attach({}, provenance(alignment: :ungrounded)))
    consolidator = Object.new
    consolidator.define_singleton_method(:reconcile_all) do |candidates:, scope:|
      candidates.first.metadata.dig("_engram", "provenance", "sources").first["alignment"] = "exact"
      [Engram::Decision.new(action: :forget, candidate: candidates.first, target_id: target.id)]
    end
    observe = described_class.new(store: store, extractor: double(extract: [candidate]),
      consolidator: consolidator, embedder: embedder)

    expect { observe.call(messages: ["turn"], scope: "u:1") }
      .to raise_error(Engram::Error, /must not mutate candidates/)
    expect(store.all(scope: "u:1")).to eq([target])
  end

  it "uses a detached candidate when a consolidator mutates its retained reference after returning" do
    target = store.add(Engram::Record.new(content: "Old", scope: "u:1", embedding: [0.0]))
    candidate = Engram::Record.new(content: "Ungrounded correction", scope: "u:1", embedding: [0.0],
      metadata: Engram::Provenance.attach({}, provenance(alignment: :ungrounded)))
    retained_candidate = nil
    consolidator = Object.new
    consolidator.define_singleton_method(:reconcile_all) do |candidates:, scope:|
      retained_candidate = candidates.first
      [Engram::Decision.new(action: :forget, candidate: retained_candidate, target_id: target.id)]
    end
    allow(store).to receive(:existing_ids) do |scope:, ids:|
      retained_candidate.metadata.dig("_engram", "provenance", "sources").first["alignment"] = "exact"
      ids
    end

    applied = described_class.new(store: store, extractor: double(extract: [candidate]),
      consolidator: consolidator, embedder: embedder)
      .call(messages: ["turn"], scope: "u:1")

    expect(applied).to be_empty
    expect(store.all(scope: "u:1")).to eq([target])
    expect(Engram::Provenance.extract(candidate.metadata).sources.first.alignment).to eq(:exact)
  end

  it "rejects deferred candidate mutation by a decision accessor before applying anything" do
    target = store.add(Engram::Record.new(content: "Old", scope: "u:1", embedding: [0.0]))
    first = Engram::Record.new(content: "Safe", scope: "u:1", embedding: [0.0])
    second = Engram::Record.new(content: "Ungrounded correction", scope: "u:1", embedding: [0.0],
      metadata: Engram::Provenance.attach({}, provenance(alignment: :ungrounded)))
    mutating_decision = Class.new(Engram::Decision) do
      def candidate
        @candidate.metadata.dig("_engram", "provenance", "sources").first["alignment"] = "exact"
        @candidate
      end
    end
    decisions = [
      Engram::Decision.new(action: :add, candidate: first),
      mutating_decision.new(action: :forget, candidate: second, target_id: target.id)
    ]
    observe = described_class.new(store: store, extractor: double(extract: [first, second]),
      consolidator: double(reconcile_all: decisions), embedder: embedder)

    expect { observe.call(messages: ["turn"], scope: "u:1") }
      .to raise_error(Engram::Error, /must not mutate candidates/)
    expect(store.all(scope: "u:1")).to eq([target])
  end

  it "rejects a behavior-bearing target_id before it can mutate verified provenance or authorize deletion" do
    target = store.add(Engram::Record.new(content: "Old", scope: "u:1", id: "victim", embedding: [0.0]))
    candidate = Engram::Record.new(content: "Ungrounded correction", scope: "u:1", embedding: [0.0],
      metadata: Engram::Provenance.attach({}, provenance(alignment: :ungrounded)))
    target_id = +"victim"
    target_id.define_singleton_method(:hash) do
      candidate.metadata.dig("_engram", "provenance", "sources").first["alignment"] = "exact"
      super()
    end
    decision = Engram::Decision.new(action: :forget, candidate: candidate, target_id: target_id)
    observe = described_class.new(store: store, extractor: double(extract: [candidate]),
      consolidator: double(reconcile_all: [decision]), embedder: embedder)

    expect { observe.call(messages: ["turn"], scope: "u:1") }
      .to raise_error(Engram::Error, /target_id/)
    expect(Engram::Provenance.extract(candidate.metadata).sources.first.alignment).to eq(:ungrounded)
    expect(store.all(scope: "u:1")).to eq([target])
  end

  it "rejects false target IDs on non-destructive decisions before applying them" do
    candidate = Engram::Record.new(content: "Candidate", scope: "u:1", embedding: [0.0])
    decision = Engram::Decision.new(action: :add, candidate: candidate, target_id: false)
    observe = described_class.new(store: store, extractor: double(extract: [candidate]),
      consolidator: double(reconcile_all: [decision]), embedder: embedder)

    expect { observe.call(messages: ["turn"], scope: "u:1") }
      .to raise_error(Engram::Error, /target_id must be a plain String or Integer/)
    expect(store.all(scope: "u:1")).to be_empty
  end

  it "rejects target_id subclasses, custom state, and coercible objects without invoking them" do
    calls = 0
    string_subclass = Class.new(String) do
      define_method(:eql?) do |other|
        calls += 1
        super(other)
      end
    end
    coercible = Object.new
    coercible.define_singleton_method(:to_str) do
      calls += 1
      "victim"
    end
    stateful = +"victim"
    stateful.instance_variable_set(:@payload, true)

    [string_subclass.new("victim"), coercible, stateful].each do |target_id|
      candidate = Engram::Record.new(content: "Correction", scope: "u:1", embedding: [0.0])
      decision = Engram::Decision.new(action: :forget, candidate: candidate, target_id: target_id)
      observe = described_class.new(store: store, extractor: double(extract: [candidate]),
        consolidator: double(reconcile_all: [decision]), embedder: embedder)

      expect { observe.call(messages: ["turn"], scope: "u:1") }
        .to raise_error(Engram::Error, /target_id must be a plain String or Integer/)
    end

    expect(calls).to eq(0)
  end

  it "preserves plain String target IDs" do
    allow(store).to receive(:existing_ids).with(scope: "u:1", ids: ["victim"]).and_return(["victim"])
    expect(store).to receive(:delete).with(scope: "u:1", id: "victim").and_return(1)
    candidate = Engram::Record.new(content: "Correction", scope: "u:1", embedding: [0.0],
      metadata: Engram::Provenance.attach({}, provenance))
    decision = Engram::Decision.new(action: :forget, candidate: candidate, target_id: +"victim")

    applied = described_class.new(store: store, extractor: double(extract: [candidate]),
      consolidator: double(reconcile_all: [decision]), embedder: embedder)
      .call(messages: ["turn"], scope: "u:1")

    expect(applied.map(&:action)).to eq([:forget])
    expect(applied.first.target_id).to eq("victim")
    expect(applied.first.target_id).not_to equal(decision.target_id)
  end

  it "reads each untrusted decision accessor once and uses only canonical values afterward" do
    candidate = Engram::Record.new(content: "Safe", scope: "u:1", embedding: [0.0])
    changing_decision = Class.new(Engram::Decision) do
      attr_reader :calls

      def initialize(...)
        super
        @calls = Hash.new(0)
      end

      %i[action candidate target_id reason].each do |attribute|
        define_method(attribute) do
          @calls[attribute] += 1
          return :destroy if attribute == :action && @calls[attribute] > 1
          return nil if attribute == :candidate && @calls[attribute] > 1

          instance_variable_get("@#{attribute}")
        end
      end
    end
    raw_decision = changing_decision.new(action: :add, candidate: candidate, reason: "safe")

    applied = described_class.new(store: store, extractor: double(extract: [candidate]),
      consolidator: double(reconcile_all: [raw_decision]), embedder: embedder)
      .call(messages: ["turn"], scope: "u:1")

    expect(applied.map(&:class)).to eq([Engram::Decision])
    expect(applied.map(&:action)).to eq([:add])
    expect(raw_decision.calls).to eq(action: 1, candidate: 1, target_id: 1, reason: 1)
    expect(store.all(scope: "u:1").map(&:content)).to eq(["Safe"])
  end

  it "preflights every decision before applying any store mutation" do
    first = Engram::Record.new(content: "Safe", scope: "u:1", embedding: [0.0])
    second = Engram::Record.new(content: "Correction", scope: "u:1", embedding: [0.0])
    forged = second.with(content: "Forged")
    decisions = [
      Engram::Decision.new(action: :add, candidate: first),
      Engram::Decision.new(action: :forget, candidate: forged, target_id: 123)
    ]
    observe = described_class.new(store: store, extractor: double(extract: [first, second]),
      consolidator: double(reconcile_all: decisions), embedder: embedder)

    expect { observe.call(messages: ["turn"], scope: "u:1") }
      .to raise_error(Engram::Error, /candidate supplied to the consolidator/)
    expect(store.all(scope: "u:1")).to be_empty
  end

  it "preflights transformed provenance before applying an earlier decision" do
    first = Engram::Record.new(content: "Safe", scope: "u:1", embedding: [0.0])
    second = Engram::Record.new(content: "Malformed later", scope: "u:1", embedding: [0.0])
    malformed = {"_engram" => {"provenance" => {"version" => 99}}}
    Engram.config.before_persist = lambda do |candidate|
      (candidate.content == second.content) ? candidate.with(metadata: malformed) : candidate
    end
    decisions = [first, second].map { |candidate| Engram::Decision.new(action: :add, candidate: candidate) }
    observe = described_class.new(store: store, extractor: double(extract: [first, second]),
      consolidator: double(reconcile_all: decisions), embedder: embedder)

    expect { observe.call(messages: ["turn"], scope: "u:1") }
      .to raise_error(Engram::Error, /unsupported provenance version 99/)
    expect(store.all(scope: "u:1")).to be_empty
  end

  it "preflights a hook-injected hostile scope before applying an earlier decision" do
    first = Engram::Record.new(content: "Safe", scope: "u:1", embedding: [0.0])
    second = Engram::Record.new(content: "Hostile later", scope: "u:1", embedding: [0.0])
    hostile_scope = +"u:2"
    hostile_scope.define_singleton_method(:==) { |_other| true }
    Engram.config.before_persist = lambda do |candidate|
      (candidate.content == second.content) ? candidate.with(scope: hostile_scope) : candidate
    end
    decisions = [first, second].map { |candidate| Engram::Decision.new(action: :add, candidate: candidate) }
    observe = described_class.new(store: store, extractor: double(extract: [first, second]),
      consolidator: double(reconcile_all: decisions), embedder: embedder)

    expect { observe.call(messages: ["turn"], scope: "u:1") }
      .to raise_error(Engram::Error, /cannot move memory across scopes/)
    expect(store.all(scope: "u:1")).to be_empty
    expect(store.all(scope: "u:2")).to be_empty
  end

  it "preflights a hostile scope injected into an update before applying an earlier add" do
    target = store.add(Engram::Record.new(content: "Old", scope: "u:1", embedding: [0.0]))
    first = Engram::Record.new(content: "Safe", scope: "u:1", embedding: [0.0])
    second = Engram::Record.new(content: "Hostile update", scope: "u:1", embedding: [0.0])
    hostile_scope = +"u:2"
    hostile_scope.define_singleton_method(:==) { |_other| true }
    Engram.config.before_persist = lambda do |candidate|
      (candidate.content == second.content) ? candidate.with(scope: hostile_scope) : candidate
    end
    decisions = [
      Engram::Decision.new(action: :add, candidate: first),
      Engram::Decision.new(action: :update, candidate: second, target_id: target.id)
    ]
    observe = described_class.new(store: store, extractor: double(extract: [first, second]),
      consolidator: double(reconcile_all: decisions), embedder: embedder)

    expect { observe.call(messages: ["turn"], scope: "u:1") }
      .to raise_error(Engram::Error, /cannot move memory across scopes/)
    expect(store.all(scope: "u:1")).to eq([target])
    expect(store.all(scope: "u:2")).to be_empty
  end

  it "preflights provenance trust laundering before applying an earlier decision" do
    first = Engram::Record.new(content: "Safe", scope: "u:1", embedding: [0.0])
    second = Engram::Record.new(content: "Ungrounded later", scope: "u:1", embedding: [0.0],
      metadata: Engram::Provenance.attach({}, provenance(alignment: :ungrounded)))
    Engram.config.before_persist = lambda do |candidate|
      (candidate.content == second.content) ? candidate.with(metadata: {}) : candidate
    end
    decisions = [first, second].map { |candidate| Engram::Decision.new(action: :add, candidate: candidate) }
    observe = described_class.new(store: store, extractor: double(extract: [first, second]),
      consolidator: double(reconcile_all: decisions), embedder: embedder)

    expect { observe.call(messages: ["turn"], scope: "u:1") }
      .to raise_error(Engram::Error, /before_persist cannot change provenance trust/)
    expect(store.all(scope: "u:1")).to be_empty
  end

  it "preflights an update target in another scope before applying an earlier add" do
    victim = store.add(Engram::Record.new(content: "Private", scope: "u:2", embedding: [0.0]))
    first = Engram::Record.new(content: "Safe", scope: "u:1", embedding: [0.0])
    second = Engram::Record.new(content: "Attack", scope: "u:1", embedding: [0.0])
    decisions = [
      Engram::Decision.new(action: :add, candidate: first),
      Engram::Decision.new(action: :update, candidate: second, target_id: victim.id)
    ]
    observe = described_class.new(store: store, extractor: double(extract: [first, second]),
      consolidator: double(reconcile_all: decisions), embedder: embedder)

    expect { observe.call(messages: ["turn"], scope: "u:1") }
      .to raise_error(Engram::Error, /no memory with id/)
    expect(store.all(scope: "u:1")).to be_empty
    expect(store.all(scope: "u:2")).to eq([victim])
  end

  it "preflights a nonexistent update target before applying an earlier add" do
    first = Engram::Record.new(content: "Safe", scope: "u:1", embedding: [0.0])
    second = Engram::Record.new(content: "Correction", scope: "u:1", embedding: [0.0])
    decisions = [
      Engram::Decision.new(action: :add, candidate: first),
      Engram::Decision.new(action: :update, candidate: second, target_id: 999_999)
    ]
    observe = described_class.new(store: store, extractor: double(extract: [first, second]),
      consolidator: double(reconcile_all: decisions), embedder: embedder)

    expect { observe.call(messages: ["turn"], scope: "u:1") }
      .to raise_error(Engram::Error, /no memory with id/)
    expect(store.all(scope: "u:1")).to be_empty
  end

  it "preflights a nonexistent forget target before applying an earlier add" do
    first = Engram::Record.new(content: "Safe", scope: "u:1", embedding: [0.0])
    second = Engram::Record.new(content: "Correction", scope: "u:1", embedding: [0.0])
    decisions = [
      Engram::Decision.new(action: :add, candidate: first),
      Engram::Decision.new(action: :forget, candidate: second, target_id: 999_999)
    ]
    observe = described_class.new(store: store, extractor: double(extract: [first, second]),
      consolidator: double(reconcile_all: decisions), embedder: embedder)

    expect { observe.call(messages: ["turn"], scope: "u:1") }
      .to raise_error(Engram::Error, /no memory with id/)
    expect(store.all(scope: "u:1")).to be_empty
  end

  it "uses scoped bulk id existence without loading all records" do
    target = store.add(Engram::Record.new(content: "Old", scope: "u:1", embedding: [0.0]))
    candidate = Engram::Record.new(content: "New", scope: "u:1", embedding: [0.0])
    decision = Engram::Decision.new(action: :update, candidate: candidate, target_id: target.id)
    allow(store).to receive(:existing_ids).and_call_original
    expect(store).not_to receive(:all)

    described_class.new(store: store, extractor: double(extract: [candidate]),
      consolidator: double(reconcile_all: [decision]), embedder: embedder)
      .call(messages: ["turn"], scope: "u:1")

    expect(store).to have_received(:existing_ids).with(scope: "u:1", ids: [target.id])
  end

  it "falls back to all for a legacy store without scoped bulk id existence" do
    target = store.add(Engram::Record.new(content: "Old", scope: "u:1", embedding: [0.0]))
    legacy_store = Class.new do
      def initialize(delegate)
        @delegate = delegate
      end

      def method_missing(name, ...)
        @delegate.public_send(name, ...)
      end

      def respond_to_missing?(name, include_private = false)
        name != :existing_ids && @delegate.respond_to?(name, include_private)
      end
    end.new(store)
    candidate = Engram::Record.new(content: "New", scope: "u:1", embedding: [0.0])
    decision = Engram::Decision.new(action: :update, candidate: candidate, target_id: target.id)
    expect(legacy_store).to receive(:all).with(scope: "u:1").and_call_original

    described_class.new(store: legacy_store, extractor: double(extract: [candidate]),
      consolidator: double(reconcile_all: [decision]), embedder: embedder)
      .call(messages: ["turn"], scope: "u:1")
  end

  it "falls back to all when the optional scoped bulk id capability is not implemented" do
    target = store.add(Engram::Record.new(content: "Old", scope: "u:1", embedding: [0.0]))
    allow(store).to receive(:existing_ids).and_raise(NotImplementedError)
    expect(store).to receive(:all).with(scope: "u:1").and_call_original
    candidate = Engram::Record.new(content: "New", scope: "u:1", embedding: [0.0])
    decision = Engram::Decision.new(action: :update, candidate: candidate, target_id: target.id)

    described_class.new(store: store, extractor: double(extract: [candidate]),
      consolidator: double(reconcile_all: [decision]), embedder: embedder)
      .call(messages: ["turn"], scope: "u:1")
  end

  it "rejects conflicting destructive decisions for one target before mutation" do
    target = store.add(Engram::Record.new(content: "Old", scope: "u:1", embedding: [0.0]))
    forget_candidate = Engram::Record.new(content: "Forget", scope: "u:1", embedding: [0.0])
    update_candidate = Engram::Record.new(content: "Update", scope: "u:1", embedding: [0.0])
    decisions = [
      Engram::Decision.new(action: :forget, candidate: forget_candidate, target_id: target.id),
      Engram::Decision.new(action: :update, candidate: update_candidate, target_id: target.id)
    ]

    expect do
      described_class.new(store: store, extractor: double(extract: [forget_candidate, update_candidate]),
        consolidator: double(reconcile_all: decisions), embedder: embedder)
        .call(messages: ["turn"], scope: "u:1")
    end.to raise_error(Engram::Error, /multiple decisions target memory/)
    expect(store.all(scope: "u:1")).to eq([target])
  end

  it "rejects duplicate updates and duplicate forgets for one target" do
    %i[update forget].each do |action|
      target = store.add(Engram::Record.new(content: "Old", scope: "u:1", embedding: [0.0]))
      candidates = 2.times.map do |index|
        Engram::Record.new(content: "Candidate #{index}", scope: "u:1", embedding: [0.0])
      end
      decisions = candidates.map do |candidate|
        Engram::Decision.new(action: action, candidate: candidate, target_id: target.id)
      end

      expect do
        described_class.new(store: store, extractor: double(extract: candidates),
          consolidator: double(reconcile_all: decisions), embedder: embedder)
          .call(messages: ["turn"], scope: "u:1")
      end.to raise_error(Engram::Error, /multiple decisions target memory/)
      expect(store.all(scope: "u:1")).to include(target)
      store.clear
    end
  end

  it "preflights a cross-scope forget target before applying an earlier add" do
    victim = store.add(Engram::Record.new(content: "Private", scope: "u:2", embedding: [0.0]))
    first = Engram::Record.new(content: "Safe", scope: "u:1", embedding: [0.0])
    second = Engram::Record.new(content: "Attack", scope: "u:1", embedding: [0.0])
    decisions = [
      Engram::Decision.new(action: :add, candidate: first),
      Engram::Decision.new(action: :forget, candidate: second, target_id: victim.id)
    ]
    observe = described_class.new(store: store, extractor: double(extract: [first, second]),
      consolidator: double(reconcile_all: decisions), embedder: embedder)

    expect { observe.call(messages: ["turn"], scope: "u:1") }
      .to raise_error(Engram::Error, /no memory with id/)
    expect(store.all(scope: "u:1")).to be_empty
    expect(store.all(scope: "u:2")).to eq([victim])
  end

  it "preflights an unsupported decision action before applying an earlier add" do
    malformed_decision = Class.new(Engram::Decision) do
      def action = :destroy
    end
    first = Engram::Record.new(content: "Safe", scope: "u:1", embedding: [0.0])
    second = Engram::Record.new(content: "Attack", scope: "u:1", embedding: [0.0])
    decisions = [
      Engram::Decision.new(action: :add, candidate: first),
      malformed_decision.new(action: :noop, candidate: second)
    ]
    observe = described_class.new(store: store, extractor: double(extract: [first, second]),
      consolidator: double(reconcile_all: decisions), embedder: embedder)

    expect { observe.call(messages: ["turn"], scope: "u:1") }
      .to raise_error(Engram::Error, /unsupported decision action :destroy/)
    expect(store.all(scope: "u:1")).to be_empty
  end

  it "rejects missing or false update targets before applying an earlier add" do
    [nil, false].each do |target_id|
      first = Engram::Record.new(content: "Safe", scope: "u:1", embedding: [0.0])
      second = Engram::Record.new(content: "Correction", scope: "u:1", embedding: [0.0])
      decisions = [
        Engram::Decision.new(action: :add, candidate: first),
        Engram::Decision.new(action: :update, candidate: second, target_id: target_id)
      ]
      observe = described_class.new(store: store, extractor: double(extract: [first, second]),
        consolidator: double(reconcile_all: decisions), embedder: embedder)

      message = target_id.nil? ? "update decision requires a target_id" : /target_id must be a plain String or Integer/
      expect { observe.call(messages: ["turn"], scope: "u:1") }.to raise_error(Engram::Error, message)
      expect(store.all(scope: "u:1")).to be_empty
    end
  end

  it "rejects missing or false forget targets before applying an earlier add" do
    [nil, false].each do |target_id|
      first = Engram::Record.new(content: "Safe", scope: "u:1", embedding: [0.0])
      second = Engram::Record.new(content: "Correction", scope: "u:1", embedding: [0.0])
      decisions = [
        Engram::Decision.new(action: :add, candidate: first),
        Engram::Decision.new(action: :forget, candidate: second, target_id: target_id)
      ]
      observe = described_class.new(store: store, extractor: double(extract: [first, second]),
        consolidator: double(reconcile_all: decisions), embedder: embedder)

      message = target_id.nil? ? "forget decision requires a target_id" : /target_id must be a plain String or Integer/
      expect { observe.call(messages: ["turn"], scope: "u:1") }.to raise_error(Engram::Error, message)
      expect(store.all(scope: "u:1")).to be_empty
    end
  end

  it "extracts and adds new memories (heuristic consolidator)" do
    completion = Engram::Adapters::FakeCompletion.new(responses: [extraction("User likes tea")])
    consolidator = Engram::Consolidators::HeuristicConsolidator.new(store: store)

    decisions = described_class.new(store: store, extractor: extractor_for(completion), consolidator: consolidator)
      .call(messages: ["I really like tea"], scope: "u:1")

    expect(decisions.map(&:action)).to eq([:add])
    expect(store.all(scope: "u:1").map(&:content)).to eq(["User likes tea"])
  end

  it "applies an UPDATE decision (llm consolidator)" do
    existing = store.add(Engram::Record.new(content: "User is on Free", scope: "u:1",
      embedding: embedder.embed("User is on Free")))
    completion = Engram::Adapters::FakeCompletion.new(responses: [
      extraction("User is on Pro"),
      {"decisions" => [{"index" => 0, "action" => "update", "target_id" => existing.id}]}
    ])
    consolidator = Engram::Consolidators::LLMConsolidator.new(store: store, completion: completion)

    described_class.new(store: store, extractor: extractor_for(completion), consolidator: consolidator)
      .call(messages: ["upgraded to pro"], scope: "u:1")

    expect(store.all(scope: "u:1").map(&:content)).to eq(["User is on Pro"])
  end

  it "applies valid decisions even when the model hallucinates an update target (llm consolidator)" do
    completion = Engram::Adapters::FakeCompletion.new(responses: [
      extraction("User likes tea", "User is on Pro"),
      {"decisions" => [
        {"index" => 0, "action" => "add"},
        {"index" => 1, "action" => "update", "target_id" => 999_999}
      ]}
    ])
    consolidator = Engram::Consolidators::LLMConsolidator.new(store: store, completion: completion)
    processed = Engram::Adapters::InMemoryProcessedTurns.new
    observe = described_class.new(store: store, extractor: extractor_for(completion),
      consolidator: consolidator, processed_turns: processed)

    decisions = observe.call(messages: ["turn"], scope: "u:1", idempotency_key: "turn-1")

    expect(decisions.map(&:action)).to eq([:add])
    expect(store.all(scope: "u:1").map(&:content)).to eq(["User likes tea"])
    # The turn completed: a retry is suppressed and does not duplicate the add.
    expect(observe.call(messages: ["turn"], scope: "u:1", idempotency_key: "turn-1")).to eq([])
    expect(store.all(scope: "u:1").size).to eq(1)
  end

  it "cannot apply malicious cross-scope update or forget decisions" do
    victim = store.add(Engram::Record.new(content: "private", scope: "u:2", embedding: [0.0]))
    candidate = Engram::Record.new(content: "attack", scope: "u:1", embedding: [0.0])
    extractor = double(extract: [candidate])

    update = double(reconcile_all: [Engram::Decision.new(action: :update,
      candidate: candidate, target_id: victim.id)])
    expect {
      described_class.new(store: store, extractor: extractor, consolidator: update, embedder: embedder)
        .call(messages: ["attack"], scope: "u:1")
    }.to raise_error(Engram::Error)

    forget = double(reconcile_all: [Engram::Decision.new(action: :forget,
      candidate: candidate, target_id: victim.id)])
    expect {
      described_class.new(store: store, extractor: extractor, consolidator: forget, embedder: embedder)
        .call(messages: ["attack"], scope: "u:1")
    }.to raise_error(Engram::Error)

    expect(store.all(scope: "u:2").map(&:content)).to eq(["private"])
  end

  it "rejects an add decision whose candidate is outside the call scope" do
    candidate = Engram::Record.new(content: "private", scope: "u:2", embedding: [0.0])
    extractor = double(extract: [candidate])
    consolidator = double(reconcile_all: [Engram::Decision.new(action: :add, candidate: candidate)])

    expect {
      described_class.new(store: store, extractor: extractor, consolidator: consolidator, embedder: embedder)
        .call(messages: ["attack"], scope: "u:1")
    }.to raise_error(Engram::Error, /across scopes/)
    expect(store.all(scope: "u:2")).to be_empty
  end

  it "does nothing when nothing is extracted" do
    completion = Engram::Adapters::FakeCompletion.new(responses: [{"facts" => []}])
    consolidator = Engram::Consolidators::HeuristicConsolidator.new(store: store)

    decisions = described_class.new(store: store, extractor: extractor_for(completion), consolidator: consolidator)
      .call(messages: ["hi"], scope: "u:1")

    expect(decisions).to eq([])
    expect(store.all(scope: "u:1")).to be_empty
  end

  it "omits decisions rejected by the persistence policy" do
    completion = Engram::Adapters::FakeCompletion.new(responses: [extraction("User API key is sk-test-secret")])
    consolidator = Engram::Consolidators::HeuristicConsolidator.new(store: store)

    decisions = described_class.new(store: store, extractor: extractor_for(completion), consolidator: consolidator)
      .call(messages: ["my API key is sk-test-secret"], scope: "u:1")

    expect(decisions).to eq([])
    expect(store.all(scope: "u:1")).to be_empty
  end

  it "rejects an add when before_persist moves the prepared record outside the call scope" do
    Engram.config.before_persist = ->(record) { record.with(scope: "u:2") }
    completion = Engram::Adapters::FakeCompletion.new(responses: [extraction("User likes tea")])
    consolidator = Engram::Consolidators::HeuristicConsolidator.new(store: store)

    expect {
      described_class.new(store: store, extractor: extractor_for(completion), consolidator: consolidator)
        .call(messages: ["I like tea"], scope: "u:1")
    }.to raise_error(Engram::Error, /across scopes/)
    expect(store.all(scope: "u:1")).to be_empty
    expect(store.all(scope: "u:2")).to be_empty
  end

  it "applies the configured before_persist hook before storing observed memories" do
    Engram.config.before_persist = lambda do |record|
      record.with(content: record.content.gsub("billing@example.test", "[REDACTED]"))
    end
    completion = Engram::Adapters::FakeCompletion.new(
      responses: [extraction("User billing email is billing@example.test")]
    )
    consolidator = Engram::Consolidators::HeuristicConsolidator.new(store: store)

    decisions = described_class.new(store: store, extractor: extractor_for(completion), consolidator: consolidator)
      .call(messages: ["billing@example.test"], scope: "u:1")

    expect(decisions.map(&:action)).to eq([:add])
    expect(store.all(scope: "u:1").map(&:content)).to eq(["User billing email is [REDACTED]"])
    expect(store.all(scope: "u:1").first.embedding)
      .to eq(embedder.embed("User billing email is [REDACTED]"))
  end

  it "skips a turn already processed under the same idempotency key" do
    completion = Engram::Adapters::FakeCompletion.new(responses: [extraction("User likes tea")])
    consolidator = Engram::Consolidators::HeuristicConsolidator.new(store: store)
    processed = Engram::Adapters::InMemoryProcessedTurns.new
    observe = described_class.new(
      store: store, extractor: extractor_for(completion), consolidator: consolidator,
      processed_turns: processed
    )

    first = observe.call(messages: ["I like tea"], scope: "u:1", idempotency_key: "turn-1")
    second = observe.call(messages: ["I like tea"], scope: "u:1", idempotency_key: "turn-1")

    expect(first.map(&:action)).to eq([:add])
    expect(second).to eq([])
    expect(store.all(scope: "u:1").size).to eq(1)
    expect(completion.calls.size).to eq(1) # extraction did not run again
  end

  it "keeps direct-use idempotency keys scoped" do
    completion = Engram::Adapters::FakeCompletion.new(responses: [extraction("One"), extraction("Two")])
    processed = Engram::Adapters::InMemoryProcessedTurns.new
    observe = described_class.new(store: store, extractor: extractor_for(completion),
      consolidator: Engram::Consolidators::HeuristicConsolidator.new(store: store), processed_turns: processed)

    observe.call(messages: ["one"], scope: "u:1", idempotency_key: "turn-1")
    observe.call(messages: ["two"], scope: "u:2", idempotency_key: "turn-1")
    expect(completion.calls.size).to eq(2)
  end

  it "releases the claim when observation raises so a retry proceeds" do
    extractor = Object.new
    calls = 0
    extractor.define_singleton_method(:extract) do |messages:, scope:|
      calls += 1
      raise "boom" if calls == 1
      []
    end
    processed = Engram::Adapters::InMemoryProcessedTurns.new
    observe = described_class.new(store: store, extractor: extractor,
      consolidator: Engram::Consolidators::HeuristicConsolidator.new(store: store), processed_turns: processed)

    expect { observe.call(messages: ["x"], scope: "u:1", idempotency_key: "turn") }.to raise_error("boom")
    expect(observe.call(messages: ["x"], scope: "u:1", idempotency_key: "turn")).to eq([])
    expect(calls).to eq(2)
  end

  it "allows exactly one concurrent extraction for a scope and key" do
    entered = Queue.new
    release = Queue.new
    extractor = Object.new
    extractor.define_singleton_method(:extract) do |messages:, scope:|
      entered << true
      release.pop
      []
    end
    observe = described_class.new(store: store, extractor: extractor,
      consolidator: Engram::Consolidators::HeuristicConsolidator.new(store: store),
      processed_turns: Engram::Adapters::InMemoryProcessedTurns.new)
    ready = Queue.new
    start = Queue.new
    threads = 8.times.map do
      Thread.new do
        ready << true
        start.pop
        begin
          observe.call(messages: ["x"], scope: "u:1", idempotency_key: "turn")
        rescue Engram::ObservationInProgressError
          :suppressed
        end
      end
    end
    8.times { ready.pop }
    8.times { start << true }
    entered.pop
    release << true
    threads.each(&:value)
    expect(entered.size).to eq(0)
  end

  it "raises instead of silently skipping when a live claim has not completed" do
    completion = Engram::Adapters::FakeCompletion.new(responses: [extraction("User likes tea")])
    processed = Engram::Adapters::InMemoryProcessedTurns.new
    processed.claim(scope: "u:1", key: "turn-1") # held elsewhere, not completed
    observe = described_class.new(
      store: store, extractor: extractor_for(completion),
      consolidator: Engram::Consolidators::HeuristicConsolidator.new(store: store),
      processed_turns: processed
    )

    expect {
      observe.call(messages: ["I like tea"], scope: "u:1", idempotency_key: "turn-1")
    }.to raise_error(Engram::ObservationInProgressError)
    expect(completion.calls).to be_empty
  end

  it "does not silently drop a turn when the adapter cannot release a failed claim" do
    # Mimics Rails::CacheProcessedTurns: release is a no-op, so a failed attempt's claim
    # suppresses work until the lease expires.
    no_release = Class.new do
      include Engram::Ports::ProcessedTurns

      def initialize
        @claims = {}
        @completed = {}
      end

      def claim(scope:, key:)
        return nil if completed?(scope: scope, key: key) || @claims[[scope, key]]

        @claims[[scope, key]] = "token"
      end

      def complete(scope:, key:, claim:)
        @completed[[scope, key]] = true
      end

      def release(scope:, key:, claim:)
        nil
      end

      def completed?(scope:, key:)
        !!@completed[[scope, key]]
      end

      def expire_lease!(scope:, key:)
        @claims.delete([scope, key])
      end
    end.new

    attempts = 0
    extractor = Object.new
    extractor.define_singleton_method(:extract) do |messages:, scope:|
      attempts += 1
      raise "provider timeout" if attempts == 1

      [Engram::Record.new(content: "User likes tea", scope: scope,
        embedding: Engram::Adapters::NullEmbedder.new.embed("User likes tea"))]
    end
    observe = described_class.new(
      store: store, extractor: extractor,
      consolidator: Engram::Consolidators::HeuristicConsolidator.new(store: store),
      processed_turns: no_release, embedder: embedder
    )
    call = -> { observe.call(messages: ["I like tea"], scope: "u:1", idempotency_key: "turn-1") }

    expect { call.call }.to raise_error("provider timeout")
    # Retry inside the lease window must fail loudly, not report success without working.
    expect { call.call }.to raise_error(Engram::ObservationInProgressError)
    expect(store.all(scope: "u:1")).to be_empty

    no_release.expire_lease!(scope: "u:1", key: "turn-1")
    expect(call.call.map(&:action)).to eq([:add])
    expect(store.all(scope: "u:1").map(&:content)).to eq(["User likes tea"])
  end
end
