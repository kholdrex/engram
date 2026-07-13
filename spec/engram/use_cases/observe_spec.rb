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
    decisions = described_class.new(store: store, extractor: extractor, consolidator: forget, embedder: embedder)
      .call(messages: ["attack"], scope: "u:1")

    expect(decisions).to be_empty
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
