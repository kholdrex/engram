# frozen_string_literal: true

RSpec.describe Engram::Internal::CandidateIntegrity do
  subject(:integrity) { described_class.new }

  def record(**attributes)
    defaults = {
      id: 7,
      content: "Candidate",
      scope: "user:1",
      embedding: [0.25, -0.0, Float::INFINITY],
      kind: :fact,
      importance: 0.75,
      metadata: {
        "nested" => [nil, true, false, :symbol, 12, 1.5, +"text"],
        "time" => Time.at(Rational(1_700_000_000_123_456_789, 1_000_000_000)).getlocal(3600)
      },
      created_at: Time.at(Rational(1_700_000_000_000_000_001, 1_000_000_000)).utc,
      last_accessed_at: nil
    }
    Engram::Record.new(**defaults.merge(attributes))
  end

  def expect_candidate_mutation(candidate = record)
    candidates = [candidate]
    snapshot = integrity.snapshot(candidates)
    yield candidate
    expect { integrity.verify!(candidates, snapshot) }
      .to raise_error(described_class::MutationError, described_class::CANDIDATE_MUTATION_MESSAGE)
  end

  it "derives its Record schema from Record's canonical state readers" do
    readers = described_class::RECORD_STATE_READERS

    expect(readers.keys).to eq(Engram::Record::STATE_READERS)
    expect(readers.values).to eq(Engram::Record::STATE_READERS.map do |attribute|
      Engram::Record.instance_method(attribute)
    end)
    expect(described_class::RECORD_INSTANCE_VARIABLES)
      .to eq(Engram::Record::STATE_READERS.map { |attribute| :"@#{attribute}" })
  end

  it "accepts the documented nested, behavior-free value domain unchanged" do
    candidates = [record]
    snapshot = integrity.snapshot(candidates)

    expect(integrity.verify!(candidates, snapshot)).to be_nil
  end

  it "rejects unsupported custom and unmarshalable values when taking the snapshot" do
    io = IO.new(IO.sysopen(File::NULL))
    unsupported = [Object.new, BasicObject.new, proc {}, io]

    begin
      unsupported.each do |value|
        expect { integrity.snapshot([record(metadata: {"value" => value})]) }
          .to raise_error(described_class::InvalidStateError, /unsupported candidate value/)
      end
    ensure
      io.close
    end
  end

  it "rejects custom equality, private singleton behavior, and extended behavior" do
    values = 3.times.map { +"value" }
    values[0].define_singleton_method(:==) { |_other| true }
    values[1].singleton_class.send(:define_method, :hidden) { true }
    values[1].singleton_class.send(:private, :hidden)
    extension = Module.new { def extension_method = true }
    values[2].extend(extension)

    values.each do |value|
      expect { integrity.snapshot([record(metadata: {"value" => value})]) }
        .to raise_error(described_class::InvalidStateError, /custom behavior/)
    end
  end

  it "detects custom equality, private behavior, and extensions added to nested values" do
    mutations = [
      ->(value) { value.define_singleton_method(:==) { |_other| true } },
      lambda do |value|
        value.singleton_class.send(:define_method, :hidden) { true }
        value.singleton_class.send(:private, :hidden)
      end,
      ->(value) { value.extend(Module.new { def extension_method = true }) }
    ]

    mutations.each do |mutation|
      expect_candidate_mutation(record(metadata: {"value" => +"plain"})) do |candidate|
        mutation.call(candidate.metadata.fetch("value"))
      end
    end
  end

  it "detects changes at every nested depth without invoking overridden traversal or equality" do
    expect_candidate_mutation do |candidate|
      candidate.metadata.fetch("nested").last.replace("changed")
    end
  end

  it "detects equivalent-value replacement, aliases becoming copies, and topology changes" do
    shared = ["same"]
    candidate = record(metadata: {"left" => shared, "right" => shared})
    snapshot = integrity.snapshot([candidate])
    candidate.metadata["right"] = ["same"]

    expect { integrity.verify!([candidate], snapshot) }
      .to raise_error(described_class::MutationError)

    expect_candidate_mutation(record(content: "same")) do |value|
      value.instance_variable_set(:@content, +"same")
    end
  end

  it "detects frozen-state changes throughout supported mutable values" do
    expect_candidate_mutation { |candidate| candidate.metadata.fetch("nested").freeze }
    expect_candidate_mutation { |candidate| candidate.metadata.fetch("nested").last.freeze }
    expect_candidate_mutation { |candidate| candidate.created_at.freeze }
    expect_candidate_mutation(&:freeze)
  end

  it "detects Time mode, offset, zone, and subnanosecond changes" do
    expect_candidate_mutation do |candidate|
      candidate.created_at.localtime(3600)
    end

    original = Time.at(Rational(10_000_000_000_001, 1_000_000_000_000)).utc
    changed = Time.at(Rational(10_000_000_000_002, 1_000_000_000_000)).utc
    expect(original.nsec).to eq(changed.nsec)
    expect_candidate_mutation(record(created_at: original)) do |candidate|
      candidate.instance_variable_set(:@created_at, changed)
    end
  end

  it "detects hidden Record state and custom Record behavior" do
    expect_candidate_mutation { |candidate| candidate.instance_variable_set(:@hidden, true) }
    expect_candidate_mutation { |candidate| candidate.define_singleton_method(:content) { "forged" } }
  end

  it "rejects cyclic values and Hash default procs" do
    cyclic = []
    cyclic << cyclic

    [cyclic, Hash.new { false }].each do |value|
      expect { integrity.snapshot([record(metadata: {"value" => value})]) }
        .to raise_error(described_class::InvalidStateError)
    end
  end

  it "detects candidate collection replacement, append, remove, and reorder" do
    mutations = [
      ->(values) { values[0] = record(content: "replacement") },
      ->(values) { values << record(content: "appended") },
      ->(values) { values.pop },
      ->(values) { values.reverse! }
    ]

    mutations.each do |mutation|
      candidates = [record(content: "first"), record(content: "second")]
      snapshot = integrity.snapshot(candidates)
      mutation.call(candidates)
      expect { integrity.verify!(candidates, snapshot) }
        .to raise_error(described_class::MutationError, described_class::COLLECTION_MUTATION_MESSAGE)
    end
  end

  it "detects collection iteration overrides, hidden state, extensions, and frozen-state changes" do
    mutations = [
      ->(values) { values.define_singleton_method(:each) { |_block| [] } },
      ->(values) { values.instance_variable_set(:@hidden, true) },
      ->(values) { values.extend(Module.new { def hidden = true }) },
      ->(values) { values.freeze }
    ]

    mutations.each do |mutation|
      candidates = [record]
      snapshot = integrity.snapshot(candidates)
      mutation.call(candidates)
      expect { integrity.verify!(candidates, snapshot) }
        .to raise_error(described_class::MutationError, described_class::COLLECTION_MUTATION_MESSAGE)
    end
  end

  it "rejects a non-plain candidates collection before reconciliation" do
    candidates = [record]
    candidates.define_singleton_method(:each) { super() }

    expect { integrity.snapshot(candidates) }
      .to raise_error(described_class::InvalidStateError, "candidates must be a plain Array")
  end
end
