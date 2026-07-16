# frozen_string_literal: true

RSpec.describe Engram::Provenance do
  def provenance
    described_class.new(
      sources: [
        described_class::Source.new(
          source_id: "conversation:42",
          source_type: "conversation",
          message_index: 3,
          role: "user",
          spans: [described_class::Span.new(start_offset: 6, end_offset: 15)],
          alignment: :exact
        )
      ],
      extractor: described_class::Extractor.new(
        name: "host-extractor", provider: "example", model: "model-1"
      ),
      confidence: 0.92
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

  # The parser deliberately caps provenance at 100 nested containers. This
  # adversarial payload is just beyond that conservative limit without risking
  # the Ruby process's stack.
  def excessively_nested_provenance(container_type)
    nested = "leaf"
    101.times do
      nested = (container_type == :hash) ? {"nested" => nested} : [nested]
    end
    provenance.to_h.merge("extension" => nested)
  end

  it "provides immutable, provider-neutral value objects with explicit offset semantics" do
    value = provenance
    span = value.sources.first.spans.first

    expect(span.offset_unit).to eq("unicode_codepoint")
    expect(span.end_exclusive?).to be(true)
    expect(value).to be_frozen
    expect(value.sources).to be_frozen
    expect(value.sources.first).to be_frozen
    expect(span).to be_frozen
    expect(value.extractor).to be_frozen
  end

  it "does not freeze mutable strings owned by its caller" do
    source_id = +"message:1"
    extractor_name = +"extractor"

    described_class::Source.new(
      source_id: source_id, source_type: "message", message_index: 0, role: "user",
      spans: [described_class::Span.new(start_offset: 0, end_offset: 1)], alignment: :inferred
    )
    described_class::Extractor.new(name: extractor_name, model: "model-1")

    expect(source_id).not_to be_frozen
    expect(extractor_name).not_to be_frozen
  end

  it "rejects unknown alignment values" do
    expect do
      described_class::Source.new(
        source_id: "message:1", source_type: "message", message_index: 0, role: "user",
        spans: [described_class::Span.new(start_offset: 0, end_offset: 1)], alignment: :approximate
      )
    end.to raise_error(ArgumentError, /alignment/)
  end

  it "rejects malformed collections and non-real confidence values consistently" do
    expect do
      described_class::Source.new(
        source_id: "message:1", source_type: "message", message_index: 0, role: "user",
        spans: nil, alignment: :exact
      )
    end.to raise_error(ArgumentError, "spans must be an array")

    expect do
      described_class.new(
        sources: nil, extractor: described_class::Extractor.new(name: "test", model: "model-1"), confidence: 1.0
      )
    end.to raise_error(ArgumentError, "sources must be an array")

    expect do
      described_class.new(
        sources: [provenance.sources.first],
        extractor: described_class::Extractor.new(name: "test", model: "model-1"), confidence: Complex(0, 1)
      )
    end.to raise_error(ArgumentError, "confidence must be an Integer or Float between 0 and 1")
  end

  it "accepts JSON-native confidence values at both boundaries" do
    [0, 1, 0.5].each do |confidence|
      value = described_class.new(
        sources: provenance.sources, extractor: provenance.extractor, confidence: confidence
      )

      expect(value.confidence).to eq(confidence)
      expect(value.to_h.fetch("confidence")).to eq(confidence)
    end
  end

  it "rejects non-JSON-native Numeric confidence values" do
    expect do
      described_class.new(
        sources: provenance.sources, extractor: provenance.extractor, confidence: Rational(1, 2)
      )
    end.to raise_error(ArgumentError, "confidence must be an Integer or Float between 0 and 1")
  end

  it "requires complete source location and extractor identity fields" do
    expect do
      described_class::Source.new(
        source_id: "message:1", source_type: "message", spans: [], alignment: :exact
      )
    end.to raise_error(ArgumentError, /missing keywords:.*message_index.*role/)

    expect do
      described_class::Source.new(
        source_id: "message:1", source_type: "message", message_index: 0, role: "user",
        spans: [], alignment: :exact
      )
    end.to raise_error(ArgumentError, "spans must contain at least one span")

    expect do
      described_class::Extractor.new(name: "test")
    end.to raise_error(ArgumentError, /missing keyword: :model/)

    expect do
      described_class.new(
        sources: [provenance.sources.first],
        extractor: described_class::Extractor.new(name: "test", model: "model-1")
      )
    end.to raise_error(ArgumentError, /missing keyword: :confidence/)
  end

  it "rejects empty and reversed character spans" do
    expect do
      described_class::Span.new(start_offset: 2, end_offset: 2)
    end.to raise_error(ArgumentError, /end_offset > start_offset/)

    expect do
      described_class::Span.new(start_offset: 3, end_offset: 2)
    end.to raise_error(ArgumentError, /end_offset > start_offset/)
  end

  it "round-trips through the versioned reserved metadata schema" do
    metadata = described_class.attach({"tenant_field" => "kept"}, provenance)

    expect(metadata).to include("tenant_field" => "kept")
    expect(metadata.dig("_engram", "provenance", "version")).to eq(1)
    expect(metadata.dig("_engram", "provenance", "sources", 0, "spans", 0)).to eq(
      "start_offset" => 6,
      "end_offset" => 15,
      "offset_unit" => "unicode_codepoint"
    )
    expect(described_class.extract(metadata)).to eq(provenance)
  end

  it "round-trips confidence through JSON serialization" do
    require "json"

    metadata = JSON.parse(JSON.generate(described_class.attach({}, provenance)))

    expect(described_class.extract(metadata)).to eq(provenance)
    expect(metadata.dig("_engram", "provenance", "confidence")).to be_a(Float)
  end

  it "coexists with embedding metadata under the reserved namespace" do
    embedding = Engram::EmbeddingMetadata.build(adapter: "test", dimensions: 3)
    metadata = Engram::EmbeddingMetadata.merge({}, embedding)
    metadata = described_class.attach(metadata, provenance)
    metadata = Engram::EmbeddingMetadata.merge(metadata, embedding)

    expect(Engram::EmbeddingMetadata.extract(metadata)).to eq(embedding)
    expect(described_class.extract(metadata)).to eq(provenance)
  end

  it "preserves arbitrary sibling schemas when provenance and embedding metadata are attached in sequence" do
    embedding = Engram::EmbeddingMetadata.build(adapter: "test", dimensions: 3)
    metadata = {"_engram" => {"future_schema" => {"enabled" => true}}}

    metadata = described_class.attach(metadata, provenance)
    metadata = Engram::EmbeddingMetadata.merge(metadata, embedding)

    expect(metadata.dig("_engram", "future_schema")).to eq("enabled" => true)
    expect(described_class.extract(metadata)).to eq(provenance)
    expect(Engram::EmbeddingMetadata.extract(metadata)).to eq(embedding)
  end

  it "preserves unrelated metadata keys and nested values exactly" do
    nested = {feature_flag: {"mode" => :strict}}
    metadata = {:tenant => nested, "tenant" => "string tenant"}

    attached = described_class.attach(metadata, provenance)

    expect(attached[:tenant]).to equal(nested)
    expect(attached).to include(:tenant => nested, "tenant" => "string tenant")
    expect(metadata).to eq(:tenant => nested, "tenant" => "string tenant")
  end

  it "merges symbol and string reserved namespaces without losing embedding metadata" do
    metadata = {
      :_engram => {embedding: {adapter: "symbol-adapter", dimensions: 3}},
      "_engram" => {"other_schema" => {enabled: true}}
    }

    attached = described_class.attach(metadata, provenance)

    expect(attached).not_to have_key(:_engram)
    expect(attached.dig("_engram", "embedding")).to eq(
      "adapter" => "symbol-adapter", "dimensions" => 3
    )
    expect(attached.dig("_engram", "other_schema")).to eq("enabled" => true)
    expect(attached.dig("_engram", "provenance")).to eq(provenance.to_h)
  end

  it "replaces provenance across reserved key styles while retaining sibling schemas" do
    metadata = {
      :_engram => {provenance: {version: 0}, embedding: {dimensions: 3}},
      "_engram" => {"provenance" => {"version" => 99}}
    }

    attached = described_class.attach(metadata, provenance)

    expect(attached.dig("_engram", "provenance")).to eq(provenance.to_h)
    expect(attached.dig("_engram", "embedding")).to eq("dimensions" => 3)
  end

  it "rejects conflicting coexisting reserved metadata rather than discarding either value" do
    metadata = {
      :_engram => {embedding: {dimensions: 3}},
      "_engram" => {"embedding" => {"dimensions" => 4}}
    }

    expect { described_class.attach(metadata, provenance) }
      .to raise_error(Engram::Error, /conflicting reserved metadata.*embedding/)
  end

  it "leaves legacy records and plain Record custom extractor results readable" do
    legacy = Engram::Record.new(
      content: "User likes tea", scope: "user:1", metadata: {"custom" => true}
    )
    legacy_reserved = Engram::Record.new(
      content: "Legacy", scope: "user:1", metadata: {"_engram" => "legacy user data"}
    )

    expect(described_class.extract(legacy.metadata)).to be_nil
    expect(described_class.extract(legacy_reserved.metadata)).to be_nil
    expect(legacy.metadata).to eq("custom" => true)
  end

  it "does not mistake unknown schema versions for current provenance" do
    metadata = {"_engram" => {"provenance" => {"version" => 2, "sources" => []}}}

    expect(described_class.extract(metadata)).to be_nil
  end

  it "keeps ordinary reads tolerant while strict persistence parsing fails closed" do
    malformed = {"_engram" => {"provenance" => {"version" => 1, "sources" => {}}}}
    future = {"_engram" => {"provenance" => {"version" => 2, "sources" => []}}}

    expect(described_class.extract(malformed)).to be_nil
    expect(described_class.extract(future)).to be_nil
    expect { described_class.extract_for_persistence(malformed) }
      .to raise_error(Engram::Error, /malformed provenance/)
    expect { described_class.extract_for_persistence(future) }
      .to raise_error(Engram::Error, /unsupported provenance version 2/)
  end

  it "distinguishes absent provenance from valid provenance during persistence parsing" do
    expect(described_class.extract_for_persistence({"host" => true})).to be_nil
    expect(described_class.extract_for_persistence({"_engram" => "legacy user data"})).to be_nil
    expect(described_class.extract_for_persistence(described_class.attach({}, provenance))).to eq(provenance)
  end

  it "does not let scalar reserved metadata mask strict provenance validation in either key style" do
    future_with_symbol_scalar = {
      "_engram" => {"provenance" => provenance.to_h.merge("version" => 99)},
      :_engram => "legacy user data"
    }
    malformed_with_string_scalar = {
      "_engram" => "legacy user data",
      :_engram => {provenance: provenance.to_h.merge("sources" => {})}
    }

    expect { described_class.extract_for_persistence(future_with_symbol_scalar) }
      .to raise_error(Engram::Error, /unsupported provenance version 99/)
    expect { described_class.extract_for_persistence(malformed_with_string_scalar) }
      .to raise_error(Engram::Error, /malformed provenance/)
  end

  it "recognizes hostile String subclass aliases for both reserved namespace keys" do
    outer_class = hostile_string_class
    outer_key = outer_class.new("_engram")
    future = {outer_key => {"provenance" => provenance.to_h.merge("version" => 99)}}
    outer_class.hostile = true

    nested_class = hostile_string_class
    nested_key = nested_class.new("provenance")
    malformed = {"_engram" => {nested_key => provenance.to_h.merge("sources" => {})}}
    nested_class.hostile = true

    expect { described_class.extract_for_persistence(future) }
      .to raise_error(Engram::Error, /unsupported provenance version 99/)
    expect { described_class.extract_for_persistence(malformed) }
      .to raise_error(Engram::Error, /malformed provenance/)
  end

  it "canonicalizes hostile String subclass keys inside a detached provenance payload" do
    key_class = hostile_string_class
    version_key = key_class.new("version")
    payload = provenance.to_h
    payload[version_key] = payload.delete("version")
    key_class.hostile = true

    expect(described_class.extract_for_persistence("_engram" => {"provenance" => payload}))
      .to eq(provenance)
  end

  it "uses core Hash and Array traversal throughout strict parsing" do
    metadata_class = Class.new(Hash) do
      def key?(_key) = false
      def [](_key) = nil
    end
    malformed = metadata_class.new.update(
      "_engram" => {"provenance" => provenance.to_h.merge("version" => 99)}
    )

    expect { described_class.extract_for_persistence(malformed) }
      .to raise_error(Engram::Error, /unsupported provenance version 99/)

    sources_class = Class.new(Array) do
      def each_with_index(&_) = []
    end
    payload = provenance.to_h
    payload["sources"] = sources_class.new(payload.fetch("sources"))

    expect(described_class.extract_for_persistence("_engram" => {"provenance" => payload}))
      .to eq(provenance)
  end

  it "does not redispatch nested Hash enumeration while detaching provenance" do
    presented = provenance.to_h
    payload = provenance.to_h.merge("version" => 99)
    payload.define_singleton_method(:each_pair) do |&block|
      return enum_for(:each_pair) unless block

      presented.each_pair(&block)
    end

    expect {
      described_class.extract_for_persistence("_engram" => {"provenance" => payload})
    }.to raise_error(Engram::Error, /unsupported provenance version 99/)
  end

  it "does not let behavior-bearing scalar leaves control strict parsing" do
    version = Object.new
    version.define_singleton_method(:==) { |_other| true }
    version_payload = provenance.to_h.merge("version" => version)

    expect {
      described_class.extract_for_persistence("_engram" => {"provenance" => version_payload})
    }.to raise_error(Engram::Error, /malformed provenance/)

    alignment = +"ungrounded"
    alignment.define_singleton_method(:to_sym) { :exact }
    alignment_payload = provenance.to_h
    alignment_payload.fetch("sources").first["alignment"] = alignment

    parsed = described_class.extract_for_persistence(
      "_engram" => {"provenance" => alignment_payload}
    )
    expect(parsed).to be_ungrounded
  end

  it "canonicalizes scalar subclasses from their underlying primitive value" do
    string_class = Class.new(String) do
      def to_s = "laundered"
      def to_str = "laundered"
      def to_sym = :exact
    end
    payload = provenance.to_h
    payload.fetch("sources").first["alignment"] = string_class.new("ungrounded")

    parsed = described_class.extract_for_persistence("_engram" => {"provenance" => payload})

    expect(parsed).to be_ungrounded
  end

  it "rejects invalid-encoding semantic strings while keeping ordinary reads tolerant" do
    invalid_string = ->(value) { "#{value}\xff".force_encoding("UTF-8") }
    cases = [
      ->(payload) { payload.dig("sources", 0)["alignment"] = invalid_string.call("ungrounded") },
      ->(payload) { payload.dig("sources", 0)["source_id"] = invalid_string.call("message:1") },
      ->(payload) { payload.dig("sources", 0)["source_type"] = invalid_string.call("message") },
      ->(payload) { payload.dig("sources", 0)["role"] = invalid_string.call("user") },
      ->(payload) { payload["extractor"]["name"] = invalid_string.call("host") },
      ->(payload) { payload["extractor"]["model"] = invalid_string.call("model-1") }
    ]

    cases.each do |mutate|
      payload = provenance.to_h
      mutate.call(payload)
      metadata = {"_engram" => {"provenance" => payload}}

      expect { described_class.extract_for_persistence(metadata) }
        .to raise_error(Engram::Error, "malformed provenance: String values must have valid encoding")
      expect(described_class.extract(metadata)).to be_nil
    end
  end

  it "rejects invalid-encoding optional and extension strings with stable strict errors" do
    invalid_string = ->(value) { "#{value}\xff".force_encoding("UTF-8") }
    cases = [
      [
        "malformed provenance: String values must have valid encoding",
        ->(payload) { payload.fetch("extractor")["provider"] = invalid_string.call("provider") }
      ],
      [
        "malformed provenance: String values must have valid encoding",
        ->(payload) { payload["extension"] = invalid_string.call("value") }
      ],
      [
        "malformed provenance: object keys must have valid encoding",
        ->(payload) { payload[invalid_string.call("extension")] = true }
      ]
    ]

    cases.each do |message, mutate|
      payload = provenance.to_h
      mutate.call(payload)
      metadata = {"_engram" => {"provenance" => payload}}

      expect { described_class.extract_for_persistence(metadata) }
        .to raise_error(Engram::Error, message)
      expect(described_class.extract(metadata)).to be_nil
    end
  end

  it "accepts safely transcodable non-UTF-8 extension strings and rejects binary strings" do
    transcodable = (+"\xE9").force_encoding("ISO-8859-1")
    metadata = {
      "_engram" => {"provenance" => provenance.to_h.merge("extension" => transcodable)}
    }

    expect(described_class.extract_for_persistence(metadata)).to eq(provenance)

    metadata["_engram"]["provenance"]["extension"] = "\xFF".b
    expect { described_class.extract_for_persistence(metadata) }
      .to raise_error(Engram::Error, "malformed provenance: String values must have valid encoding")
    expect(described_class.extract(metadata)).to be_nil
  end

  it "accepts safely transcodable non-UTF-8 extension keys and rejects binary keys" do
    payload = provenance.to_h
    payload[(+"\xE9").force_encoding("ISO-8859-1")] = true
    metadata = {"_engram" => {"provenance" => payload}}

    expect(described_class.extract_for_persistence(metadata)).to eq(provenance)

    payload.delete((+"\xE9").force_encoding("ISO-8859-1"))
    payload["\xFF".b] = true
    expect { described_class.extract_for_persistence(metadata) }
      .to raise_error(Engram::Error, "malformed provenance: object keys must have valid encoding")
    expect(described_class.extract(metadata)).to be_nil
  end

  it "rejects non-finite extension floats as non-JSON-native scalars" do
    [Float::NAN, Float::INFINITY, -Float::INFINITY].each do |scalar|
      metadata = {
        "_engram" => {"provenance" => provenance.to_h.merge("extension" => scalar)}
      }

      expect { described_class.extract_for_persistence(metadata) }
        .to raise_error(
          Engram::Error,
          "malformed provenance: scalar values must be JSON-native primitives"
        )
      expect(described_class.extract(metadata)).to be_nil
    end
  end

  it "rejects cyclic provenance containers with a stable strict parsing error" do
    payload = provenance.to_h
    payload["cycle"] = payload

    expect {
      described_class.extract_for_persistence("_engram" => {"provenance" => payload})
    }.to raise_error(Engram::Error, /malformed provenance: cyclic containers are unsupported/)
    expect(described_class.extract("_engram" => {"provenance" => payload})).to be_nil
  end

  it "rejects excessively nested Hash and Array provenance with a stable bounded-depth error" do
    %i[hash array].each do |container_type|
      metadata = {
        "_engram" => {"provenance" => excessively_nested_provenance(container_type)}
      }

      expect { described_class.extract_for_persistence(metadata) }
        .to raise_error(
          Engram::Error,
          "malformed provenance at _engram.provenance: nesting exceeds maximum depth of 100"
        )
      expect(described_class.extract(metadata)).to be_nil
    end
  end

  it "does not canonicalize unrelated opaque application metadata values" do
    value_class = Class.new do
      def initialize(payload)
        @payload = payload
      end
    end
    value_object = value_class.new("application state")
    application_object = Object.new
    metadata = described_class.attach(
      {"value_object" => value_object, "application_object" => application_object},
      provenance
    )

    expect(described_class.extract_for_persistence(metadata)).to eq(provenance)
    expect(metadata.fetch("value_object")).to equal(value_object)
    expect(metadata.fetch("application_object")).to equal(application_object)
  end

  it "reports whether any source is structurally marked ungrounded" do
    source = provenance.sources.first
    ungrounded_source = described_class::Source.new(
      source_id: source.source_id, source_type: source.source_type,
      message_index: source.message_index, role: source.role, spans: source.spans,
      alignment: :ungrounded
    )

    expect(provenance).not_to be_ungrounded
    expect(described_class.new(sources: [source, ungrounded_source],
      extractor: provenance.extractor, confidence: 0.8)).to be_ungrounded
  end

  it "reports malformed current-version payloads as stable strict parsing errors with their path" do
    malformed = [
      [{"sources" => {}}, "_engram.provenance.sources"],
      [{"sources" => [nil]}, "_engram.provenance.sources[0]"],
      [{"sources" => [{"spans" => {}}]}, "_engram.provenance.sources[0].spans"],
      [{"sources" => [{"spans" => [nil]}]}, "_engram.provenance.sources[0].spans[0]"],
      [{"extractor" => []}, "_engram.provenance.extractor"]
    ]

    malformed.each do |override, path|
      payload = provenance.to_h.merge(override)
      metadata = {"_engram" => {"provenance" => payload}}

      expect(described_class.extract(metadata)).to be_nil
      expect { described_class.extract_for_persistence(metadata) }
        .to raise_error(Engram::Error, /malformed provenance at #{Regexp.escape(path)}/)
    end
  end

  it "rejects blank required identity fields" do
    expect do
      described_class::Extractor.new(name: "  ", model: "model-1")
    end.to raise_error(ArgumentError, "extractor name is required")

    expect do
      described_class::Source.new(
        source_id: "\t", source_type: "message", message_index: 0, role: "user",
        spans: [described_class::Span.new(start_offset: 0, end_offset: 1)], alignment: :exact
      )
    end.to raise_error(ArgumentError, "source_id is required")
  end
end
