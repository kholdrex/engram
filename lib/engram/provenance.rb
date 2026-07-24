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
    # Includes arbitrary extension fields. Keeping this conservative leaves ample
    # Ruby stack headroom while covering the schema's ordinary nesting.
    MAX_PROVENANCE_NESTING = 100
    private_constant :MAX_PROVENANCE_NESTING

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

      def initialize(source_id:, source_type:, message_index:, role:, spans:, alignment:)
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
        @role = role.to_s.dup.freeze
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

      def initialize(name:, model:, provider: nil)
        raise ArgumentError, "extractor name is required" if name.to_s.strip.empty?
        raise ArgumentError, "extractor model is required" if model.to_s.strip.empty?

        @name = name.to_s.dup.freeze
        @provider = provider&.to_s&.dup&.freeze
        @model = model.to_s.dup.freeze
        freeze
      end

      def ==(other)
        other.is_a?(self.class) && to_h == other.to_h
      end
      alias_method :eql?, :==

      def hash = to_h.hash

      def to_h
        {"name" => name, "model" => model}.tap do |data|
          data["provider"] = provider if provider
        end
      end
    end

    attr_reader :sources, :extractor, :confidence

    def initialize(sources:, extractor:, confidence:)
      raise ArgumentError, "sources must be an array" unless sources.is_a?(Array)
      raise ArgumentError, "sources must contain at least one source" if sources.empty?
      @sources = sources.map do |source|
        raise ArgumentError, "sources must contain Provenance::Source values" unless source.is_a?(Source)
        source
      end.freeze
      raise ArgumentError, "extractor must be a Provenance::Extractor" unless extractor.is_a?(Extractor)
      valid_confidence = (confidence.is_a?(Integer) || confidence.is_a?(Float)) && confidence.between?(0, 1)
      unless valid_confidence
        raise ArgumentError, "confidence must be an Integer or Float between 0 and 1"
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

    def ungrounded?
      sources.any? { |source| source.alignment == :ungrounded }
    end

    class << self
      def attach(metadata, provenance)
        raise ArgumentError, "provenance must be a Provenance value" unless provenance.is_a?(self)

        Engram::ReservedMetadata.attach(metadata, METADATA_KEY, provenance.to_h)
      end

      def extract(metadata)
        extract_for_persistence(metadata)
      rescue Engram::Error
        nil
      end

      # Strict parser used by writers. Ordinary reads intentionally use #extract and
      # tolerate malformed or future schemas, but an older writer must not silently
      # persist provenance it cannot validate.
      def extract_for_persistence(metadata)
        data = canonical_payload_for_persistence(metadata)
        data && from_h(data)
      end

      # Returns a behavior-free canonical copy of the complete validated payload,
      # including extension fields which the value object intentionally does not expose.
      def canonical_payload_for_persistence(metadata)
        metadata ||= {}
        return nil unless core_kind_of?(metadata, Hash)

        reserved_values = core_hash_values(metadata, RESERVED_KEY, :_engram)
        reserved_hashes = reserved_values.select { |value| core_kind_of?(value, Hash) }
        provenance_values = reserved_hashes
          .flat_map { |reserved| core_hash_values(reserved, METADATA_KEY, :provenance) }
        if provenance_values.empty?
          reject_non_hash_reserved_values!(reserved_values)
          return nil
        end

        reserved = provenance_values.reduce({}) do |merged, value|
          detached = detach_provenance_container(value)
          Engram::ReservedMetadata.merge(merged, METADATA_KEY => detached)
        end
        data = reserved.fetch(METADATA_KEY)
        unless data.is_a?(Hash)
          raise Engram::Error, "malformed provenance at _engram.provenance: expected an object"
        end
        unless data.key?("version")
          raise Engram::Error, "malformed provenance at _engram.provenance.version: version is required"
        end
        unless data["version"] == SCHEMA_VERSION
          raise Engram::Error, "unsupported provenance version #{data["version"].inspect}"
        end

        # Validate the known schema while retaining the already detached extension data.
        from_h(data)
        reject_non_hash_reserved_values!(reserved_values)
        data
      end

      # Replaces validated provenance aliases with the detached payload in a plain
      # reserved namespace. Unrelated application metadata values remain untouched.
      def canonical_metadata_for_persistence(metadata)
        payload = canonical_payload_for_persistence(metadata)
        return metadata unless payload

        # Copy the core table without rehashing arbitrary application keys, then
        # remove only the reserved aliases through bound Hash traversal.
        application_metadata = Hash.instance_method(:transform_values).bind_call(metadata) { |value| value }
        Hash.instance_method(:delete_if).bind_call(application_metadata) do |key, _value|
          reserved_key_style(key)
        end
        string_reserved = []
        symbol_reserved = []
        Hash.instance_method(:each_pair).bind_call(metadata) do |key, value|
          case reserved_key_style(key)
          when :string then string_reserved << value
          when :symbol then symbol_reserved << value
          end
        end

        reserved = (string_reserved + symbol_reserved).reduce({}) do |merged, value|
          siblings = {}
          Hash.instance_method(:each_pair).bind_call(value) do |key, nested|
            siblings[key] = nested unless provenance_key_alias?(key)
          end
          Engram::ReservedMetadata.merge(merged, Engram::ReservedMetadata.normalize(siblings))
        end
        application_metadata[RESERVED_KEY] = reserved.merge(METADATA_KEY => payload)
        application_metadata
      end

      # Represents the complete canonical payload without relying on value #==, #eql?,
      # or #hash implementations. Explicit structural and scalar tags preserve key,
      # value, and container roles. Integers remain distinct from Floats, whose packed
      # IEEE 754 bits preserve distinctions such as negative zero.
      def canonical_integrity_representation_for_persistence(metadata)
        data = canonical_payload_for_persistence(metadata)
        data && provenance_integrity_representation(data)
      end

      private

      def reject_non_hash_reserved_values!(reserved_values)
        return if reserved_values.all? { |value| core_kind_of?(value, Hash) }

        raise Engram::Error, "metadata key #{RESERVED_KEY.inspect} is reserved for Engram embedding metadata"
      end

      def reserved_key_style(key)
        key_class = Object.instance_method(:class).bind_call(key)
        return :symbol if key.equal?(:_engram) && key_class.equal?(Symbol)
        :string if core_kind_of?(key, String) && String.instance_method(:==).bind_call(key, RESERVED_KEY)
      rescue TypeError
        nil
      end

      def provenance_key_alias?(key)
        core_key_equal?(key, METADATA_KEY, :provenance)
      end

      # Finds trusted namespace keys through Hash's implementation rather than any
      # behavior supplied by a Hash subclass or singleton class.
      def core_hash_values(hash, string_key, symbol_key)
        values = []
        Hash.instance_method(:each_pair).bind_call(hash) do |key, value|
          values << value if core_key_equal?(key, string_key, symbol_key)
        end
        values
      end

      def core_key_equal?(key, string_key, symbol_key)
        key_class = Object.instance_method(:class).bind_call(key)
        return key.equal?(symbol_key) if key_class.equal?(Symbol)
        return false unless core_kind_of?(key, String)

        # Compare the stored String bytes without dispatching subclass #==/#eql?.
        String.instance_method(:==).bind_call(key, string_key)
      rescue TypeError
        false
      end

      # Detaches the provenance subtree into plain containers and trusted primitive
      # leaves. Container subclasses retain their stored contents, while Strings are
      # exposed without subclass behavior and canonicalized to UTF-8. Other metadata
      # is deliberately left untouched.
      def detach_provenance_container(value, active = {}.compare_by_identity, depth = 0)
        if core_kind_of?(value, Hash)
          with_acyclic_container(value, active) do
            copy = {}
            Hash.instance_method(:each_pair).bind_call(value) do |key, nested|
              normalized_key = provenance_key(key)
              normalized_value = detach_nested_provenance(nested, active, depth)
              if copy.key?(normalized_key)
                # Both collision inputs have already passed the same depth bound;
                # merging them cannot introduce a deeper path than either input.
                copy.replace(Engram::ReservedMetadata.merge(copy, normalized_key => normalized_value))
              else
                copy[normalized_key] = normalized_value
              end
            end
            copy
          end
        elsif core_kind_of?(value, Array)
          with_acyclic_container(value, active) do
            copy = []
            Array.instance_method(:each).bind_call(value) do |nested|
              copy << detach_nested_provenance(nested, active, depth)
            end
            copy
          end
        else
          canonical_provenance_scalar(value)
        end
      end

      def detach_nested_provenance(value, active, parent_depth)
        if parent_depth >= MAX_PROVENANCE_NESTING && provenance_container?(value)
          raise Engram::Error,
            "malformed provenance at _engram.provenance: nesting exceeds maximum depth of #{MAX_PROVENANCE_NESTING}"
        end

        detach_provenance_container(value, active, parent_depth + 1)
      end

      def provenance_container?(value)
        core_kind_of?(value, Hash) || core_kind_of?(value, Array)
      end

      def canonical_provenance_scalar(value)
        value_class = Object.instance_method(:class).bind_call(value)
        return nil if value_class.equal?(NilClass)
        return true if value_class.equal?(TrueClass)
        return false if value_class.equal?(FalseClass)
        return value if value_class.equal?(Symbol) || value_class.equal?(Integer)
        if value_class.equal?(Float)
          unless Float.instance_method(:finite?).bind_call(value)
            raise Engram::Error, "malformed provenance: scalar values must be JSON-native primitives"
          end

          return value
        end

        if core_kind_of?(value, String)
          # Bound String#to_s exposes a subclass's underlying string as an exact String;
          # bound #dup then removes any singleton methods from an exact String value.
          string = String.instance_method(:to_s).bind_call(value)
          string = canonical_utf8_string(string)
          unless string
            raise Engram::Error, "malformed provenance: String values must have valid encoding"
          end

          return String.instance_method(:dup).bind_call(string)
        end

        raise Engram::Error, "malformed provenance: scalar values must be JSON-native primitives"
      rescue TypeError
        raise Engram::Error, "malformed provenance: scalar values must be JSON-native primitives"
      end

      def provenance_integrity_representation(value)
        value_class = Object.instance_method(:class).bind_call(value)
        if value_class.equal?(Hash)
          fields = {}
          Hash.instance_method(:each_pair).bind_call(value) do |key, nested|
            fields[key] = provenance_integrity_representation(nested)
          end
          return [:object, fields]
        end
        if value_class.equal?(Array)
          entries = []
          Array.instance_method(:each).bind_call(value) do |nested|
            entries << provenance_integrity_representation(nested)
          end
          return [:array, entries]
        end
        return [:null] if value_class.equal?(NilClass)
        return [:boolean, true] if value_class.equal?(TrueClass)
        return [:boolean, false] if value_class.equal?(FalseClass)
        if value_class.equal?(Integer)
          return [:integer, Integer.instance_method(:to_s).bind_call(value)]
        end
        if value_class.equal?(Float)
          bits = Array.instance_method(:pack).bind_call([value], "G")
          return [:float, bits]
        end
        return [:symbol, Symbol.instance_method(:to_s).bind_call(value)] if value_class.equal?(Symbol)
        return [:string, value] if value_class.equal?(String)

        # canonical_payload_for_persistence has already rejected every other type.
        raise Engram::Error, "malformed provenance: scalar values must be JSON-native primitives"
      rescue TypeError
        raise Engram::Error, "malformed provenance: scalar values must be JSON-native primitives"
      end

      def provenance_key(key)
        key_class = Object.instance_method(:class).bind_call(key)
        string = if key_class.equal?(Symbol)
          Symbol.instance_method(:to_s).bind_call(key)
        elsif core_kind_of?(key, String)
          # Bound String#to_s returns the underlying bytes as an exact String without
          # dispatching subclass behavior; #dup strips exact-String singleton methods.
          String.instance_method(:to_s).bind_call(key)
        else
          raise Engram::Error, "malformed provenance: object keys must be String or Symbol values"
        end
        string = canonical_utf8_string(string)
        unless string
          raise Engram::Error, "malformed provenance: object keys must have valid encoding"
        end

        String.instance_method(:dup).bind_call(string)
      rescue TypeError
        raise Engram::Error, "malformed provenance: object keys must be String or Symbol values"
      end

      def canonical_utf8_string(string)
        return unless String.instance_method(:valid_encoding?).bind_call(string)

        String.instance_method(:encode).bind_call(string, Encoding::UTF_8)
      rescue EncodingError
        nil
      end

      def with_acyclic_container(value, active)
        raise Engram::Error, "malformed provenance: cyclic containers are unsupported" if active.key?(value)

        active[value] = true
        yield
      ensure
        active.delete(value)
      end

      def core_kind_of?(value, klass)
        Object.instance_method(:is_a?).bind_call(value, klass)
      rescue TypeError
        false
      end

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
      rescue ArgumentError, TypeError, KeyError, NoMethodError, EncodingError => error
        raise Engram::Error, "malformed provenance at #{path}: #{error.message}"
      end

      def symbolize_extractor(data)
        {name: data["name"], provider: data["provider"], model: data["model"]}
      end
    end
  end
end
