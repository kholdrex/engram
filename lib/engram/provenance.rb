# frozen_string_literal: true

module Engram
  # Provider-neutral source provenance stored in Record metadata.
  #
  # Offsets are zero-based Unicode codepoint indexes into one host-owned source
  # message. The end offset is exclusive. Engram stores references and spans,
  # never the source text itself.
  class Provenance
    RESERVED_KEY = "_engram"
    METADATA_KEY = "provenance"
    SCHEMA_VERSION = 1
    ALIGNMENTS = %i[exact normalized inferred ungrounded].freeze

    class Span
      OFFSET_UNIT = "unicode_codepoint"

      attr_reader :start_offset, :end_offset, :offset_unit

      def initialize(start_offset:, end_offset:, offset_unit: OFFSET_UNIT)
        unless start_offset.is_a?(Integer) && end_offset.is_a?(Integer) &&
            start_offset >= 0 && end_offset > start_offset
          raise ArgumentError, "span offsets must be non-negative integers with end_offset > start_offset"
        end
        raise ArgumentError, "unsupported offset unit" unless offset_unit.to_s == OFFSET_UNIT

        @start_offset = start_offset
        @end_offset = end_offset
        @offset_unit = OFFSET_UNIT
        freeze
      end

      def end_exclusive? = true

      def ==(other)
        other.is_a?(self.class) && to_h == other.to_h
      end
      alias_method :eql?, :==

      def hash = to_h.hash

      def to_h
        {"start_offset" => start_offset, "end_offset" => end_offset, "offset_unit" => offset_unit}
      end
    end

    class Source
      attr_reader :source_id, :source_type, :message_index, :role, :spans, :alignment

      def initialize(source_id:, source_type:, spans:, alignment:, message_index: nil, role: nil)
        raise ArgumentError, "source_id is required" if source_id.to_s.strip.empty?
        raise ArgumentError, "source_type is required" if source_type.to_s.strip.empty?
        unless message_index.is_a?(Integer) && !message_index.negative?
          raise ArgumentError, "message_index must be a non-negative integer"
        end
        raise ArgumentError, "role is required" if role.to_s.strip.empty?

        unless alignment.is_a?(String) || alignment.is_a?(Symbol)
          raise ArgumentError, "unknown alignment #{alignment.inspect}"
        end
        normalized_alignment = alignment.to_sym
        raise ArgumentError, "unknown alignment #{alignment.inspect}" unless ALIGNMENTS.include?(normalized_alignment)

        @source_id = source_id.to_s.dup.freeze
        @source_type = source_type.to_s.dup.freeze
        @message_index = message_index
        @role = role&.to_s&.dup&.freeze
        raise ArgumentError, "spans must be an array" unless spans.is_a?(Array)
        raise ArgumentError, "spans must contain at least one span" if spans.empty?
        @spans = spans.map do |span|
          raise ArgumentError, "spans must contain Provenance::Span values" unless span.is_a?(Span)
          span
        end.freeze
        @alignment = normalized_alignment
        freeze
      end

      def ==(other)
        other.is_a?(self.class) && to_h == other.to_h
      end
      alias_method :eql?, :==

      def hash = to_h.hash

      def to_h
        data = {
          "source_id" => source_id,
          "source_type" => source_type,
          "spans" => spans.map(&:to_h),
          "alignment" => alignment.to_s
        }
        data["message_index"] = message_index
        data["role"] = role
        data
      end
    end

    class Extractor
      attr_reader :name, :provider, :model

      def initialize(name:, provider: nil, model: nil)
        raise ArgumentError, "extractor name is required" if name.to_s.strip.empty?
        raise ArgumentError, "extractor model is required" if model.to_s.strip.empty?

        @name = name.to_s.dup.freeze
        @provider = provider&.to_s&.dup&.freeze
        @model = model&.to_s&.dup&.freeze
        freeze
      end

      def ==(other)
        other.is_a?(self.class) && to_h == other.to_h
      end
      alias_method :eql?, :==

      def hash = to_h.hash

      def to_h
        {"name" => name}.tap do |data|
          data["provider"] = provider if provider
          data["model"] = model if model
        end
      end
    end

    attr_reader :sources, :extractor, :confidence

    def initialize(sources:, extractor:, confidence: nil)
      raise ArgumentError, "sources must be an array" unless sources.is_a?(Array)
      raise ArgumentError, "sources must contain at least one source" if sources.empty?
      @sources = sources.map do |source|
        raise ArgumentError, "sources must contain Provenance::Source values" unless source.is_a?(Source)
        source
      end.freeze
      raise ArgumentError, "extractor must be a Provenance::Extractor" unless extractor.is_a?(Extractor)
      if !confidence.is_a?(Numeric) || !confidence.real? || !confidence.between?(0, 1)
        raise ArgumentError, "confidence must be between 0 and 1"
      end

      @extractor = extractor
      @confidence = confidence
      freeze
    end

    def ==(other)
      other.is_a?(self.class) && to_h == other.to_h
    end
    alias_method :eql?, :==

    def hash = to_h.hash

    def to_h
      {
        "version" => SCHEMA_VERSION,
        "sources" => sources.map(&:to_h),
        "extractor" => extractor.to_h,
        "confidence" => confidence
      }
    end

    class << self
      def attach(metadata, provenance)
        raise ArgumentError, "provenance must be a Provenance value" unless provenance.is_a?(self)

        Engram::ReservedMetadata.attach(metadata, METADATA_KEY, provenance.to_h)
      end

      def extract(metadata)
        metadata = deep_stringify(metadata || {})
        return nil unless metadata.is_a?(Hash)

        reserved = metadata[RESERVED_KEY]
        return nil unless reserved.is_a?(Hash)

        data = reserved[METADATA_KEY]
        return nil unless data.is_a?(Hash) && data["version"] == SCHEMA_VERSION

        from_h(data)
      end

      private

      def from_h(data)
        sources = provenance_array(data["sources"], "_engram.provenance.sources")
        extractor_data = provenance_hash(data["extractor"], "_engram.provenance.extractor")

        parsed_sources = sources.each_with_index.map do |source, source_index|
          source_path = "_engram.provenance.sources[#{source_index}]"
          source = provenance_hash(source, source_path)
          spans = provenance_array(source["spans"], "#{source_path}.spans")
          parsed_spans = spans.each_with_index.map do |span, span_index|
            span_path = "#{source_path}.spans[#{span_index}]"
            span = provenance_hash(span, span_path)
            build_provenance_value(span_path) do
              Span.new(
                start_offset: span["start_offset"],
                end_offset: span["end_offset"],
                offset_unit: span["offset_unit"]
              )
            end
          end

          build_provenance_value(source_path) do
            Source.new(
              source_id: source["source_id"],
              source_type: source["source_type"],
              message_index: source["message_index"],
              role: source["role"],
              spans: parsed_spans,
              alignment: source["alignment"]
            )
          end
        end

        extractor = build_provenance_value("_engram.provenance.extractor") do
          Extractor.new(**symbolize_extractor(extractor_data))
        end
        build_provenance_value("_engram.provenance") do
          new(sources: parsed_sources, extractor: extractor, confidence: data["confidence"])
        end
      end

      def provenance_hash(value, path)
        return value if value.is_a?(Hash)

        raise Engram::Error, "malformed provenance at #{path}: expected an object"
      end

      def provenance_array(value, path)
        return value if value.is_a?(Array)

        raise Engram::Error, "malformed provenance at #{path}: expected an array"
      end

      def build_provenance_value(path)
        yield
      rescue ArgumentError, TypeError, KeyError, NoMethodError => error
        raise Engram::Error, "malformed provenance at #{path}: #{error.message}"
      end

      def symbolize_extractor(data)
        {name: data["name"], provider: data["provider"], model: data["model"]}
      end

      def deep_stringify(value)
        case value
        when Hash
          value.each_with_object({}) { |(key, nested), out| out[key.to_s] = deep_stringify(nested) }
        when Array
          value.map { |nested| deep_stringify(nested) }
        else
          value
        end
      end
    end
  end
end
