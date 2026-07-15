# frozen_string_literal: true

require "bigdecimal"
require "date"

module Engram
  module Internal
    # Captures reconciliation candidates and verifies that an untrusted custom
    # consolidator treated both the records and their collection as read-only.
    #
    # This intentionally supports only the exact, behavior-free value domain
    # documented for custom consolidators. Core-method binding prevents custom
    # equality, traversal, and serialization hooks from hiding mutations.
    class CandidateIntegrity
      class Error < StandardError; end
      class InvalidStateError < Error; end
      class MutationError < Error; end

      COLLECTION_MUTATION_MESSAGE = "consolidators must not mutate the candidates collection"
      CANDIDATE_MUTATION_MESSAGE = "consolidators must not mutate candidates"

      RECORD_STATE_READERS = Engram::Record::STATE_READERS.to_h do |attribute|
        [attribute, Engram::Record.instance_method(attribute)]
      end.freeze
      RECORD_INSTANCE_VARIABLES = Engram::Record::STATE_READERS.map { |attribute| :"@#{attribute}" }.freeze

      Snapshot = Struct.new(:collection, :collection_state, :records)
      private_constant :Snapshot

      # Retains the snapshotted object so object-id reuse cannot make a replacement
      # look identical after the original nested value becomes unreachable.
      class IdentityToken
        def initialize(value)
          @value = value
        end

        def ==(other)
          Object.instance_method(:instance_of?).bind_call(other, IdentityToken) &&
            Object.instance_method(:equal?).bind_call(@value, other.value)
        end

        protected

        attr_reader :value
      end
      private_constant :IdentityToken

      def snapshot(candidates)
        collection = snapshot_collection(candidates)
        records = collection.map { |candidate| [candidate, snapshot_record(candidate)] }
        Snapshot.new(collection, collection_state(candidates), records)
      end

      def verify!(candidates, snapshot)
        verify_collection!(candidates, snapshot.collection, snapshot.collection_state)
        changed = snapshot.records.any? do |candidate, record_snapshot|
          snapshot_record(candidate) != record_snapshot
        end
        raise MutationError, CANDIDATE_MUTATION_MESSAGE if changed
      rescue InvalidStateError => error
        raise MutationError, CANDIDATE_MUTATION_MESSAGE, error.backtrace
      end

      # Validates a candidate without dispatching through any of its readers.
      def validate!(candidate)
        snapshot_record(candidate)
        nil
      end

      # Returns a deep, behavior-free copy whose nested state shares no mutable
      # references with the candidate supplied to an untrusted consolidator.
      def detach(candidate)
        validate_detachable_record!(candidate)
        attributes = RECORD_STATE_READERS.to_h do |attribute, reader|
          [attribute, duplicate_value(reader.bind_call(candidate))]
        end
        Engram::Record.new(**attributes)
      end

      private

      def duplicate_value(value, active = {}.compare_by_identity)
        value_class = plain_class(value)
        if custom_behavior?(value, value_class) || !Object.instance_method(:instance_variables).bind_call(value).empty?
          raise InvalidStateError, "unsupported candidate value"
        end

        if value_class.equal?(String) || value_class.equal?(Time) || value_class.equal?(Date)
          Object.instance_method(:dup).bind_call(value)
        elsif value_class.equal?(Array)
          with_acyclic_value(value, active) do
            copy = []
            Array.instance_method(:each).bind_call(value) { |element| copy << duplicate_value(element, active) }
            copy
          end
        elsif value_class.equal?(Hash)
          duplicate_hash(value, active)
        else
          # The remaining supported scalar values are immutable.
          canonical_value(value, active)
          value
        end
      end

      def duplicate_hash(value, active)
        default_proc = Hash.instance_method(:default_proc).bind_call(value)
        raise InvalidStateError, "unsupported candidate value Hash with a default proc" if default_proc

        with_acyclic_value(value, active) do
          copy = {}
          copy.compare_by_identity if Hash.instance_method(:compare_by_identity?).bind_call(value)
          Hash.instance_method(:each_pair).bind_call(value) do |key, nested_value|
            copy[duplicate_value(key, active)] = duplicate_value(nested_value, active)
          end
          copy.default = duplicate_value(Hash.instance_method(:default).bind_call(value), active)
          copy
        end
      end

      def snapshot_collection(candidates)
        unless Object.instance_method(:instance_of?).bind_call(candidates, Array) &&
            !custom_behavior?(candidates, Array) &&
            Object.instance_method(:instance_variables).bind_call(candidates).empty?
          raise InvalidStateError, "candidates must be a plain Array"
        end

        snapshot = []
        Array.instance_method(:each).bind_call(candidates) { |candidate| snapshot << candidate }
        snapshot
      end

      def collection_state(candidates)
        [identity(candidates), frozen?(candidates)]
      end

      def verify_collection!(candidates, snapshot, original_state)
        unless Object.instance_method(:instance_of?).bind_call(candidates, Array) &&
            !custom_behavior?(candidates, Array) &&
            Object.instance_method(:instance_variables).bind_call(candidates).empty? &&
            collection_state(candidates) == original_state
          raise MutationError, COLLECTION_MUTATION_MESSAGE
        end

        current_size = Array.instance_method(:length).bind_call(candidates)
        original_size = Array.instance_method(:length).bind_call(snapshot)
        unchanged = current_size == original_size && original_size.times.all? do |index|
          current = Array.instance_method(:[]).bind_call(candidates, index)
          original = Array.instance_method(:[]).bind_call(snapshot, index)
          Object.instance_method(:equal?).bind_call(current, original)
        end
        return if unchanged

        raise MutationError, COLLECTION_MUTATION_MESSAGE
      end

      def snapshot_record(candidate)
        unless plain_record?(candidate)
          raise InvalidStateError, "candidate must be a plain Engram::Record"
        end

        instance_variables = Object.instance_method(:instance_variables).bind_call(candidate)
        unless instance_variables.sort == RECORD_INSTANCE_VARIABLES.sort
          unexpected = instance_variables - RECORD_INSTANCE_VARIABLES
          missing = RECORD_INSTANCE_VARIABLES - instance_variables
          details = []
          details << "unexpected: #{unexpected.map(&:inspect).join(", ")}" unless unexpected.empty?
          details << "missing: #{missing.map(&:inspect).join(", ")}" unless missing.empty?
          raise InvalidStateError,
            "candidate Record must have exactly the expected instance variables (#{details.join("; ")})"
        end

        [frozen?(candidate), RECORD_STATE_READERS.to_h do |attribute, reader|
          [attribute, canonical_value(reader.bind_call(candidate))]
        end]
      end

      def canonical_value(value, active = {}.compare_by_identity)
        value_class = plain_class(value)
        if custom_behavior?(value, value_class)
          raise InvalidStateError, "unsupported candidate value with custom behavior"
        end
        unless Object.instance_method(:instance_variables).bind_call(value).empty?
          raise InvalidStateError, "unsupported candidate value with custom state"
        end

        if value_class.equal?(NilClass)
          [:nil]
        elsif value_class.equal?(TrueClass)
          [:boolean, true]
        elsif value_class.equal?(FalseClass)
          [:boolean, false]
        elsif value_class.equal?(String)
          encoding = String.instance_method(:encoding).bind_call(value)
          bytes = String.instance_method(:b).bind_call(value)
          [:string, identity(value), frozen?(value), encoding, bytes]
        elsif value_class.equal?(Symbol)
          [:symbol, value]
        elsif value_class.equal?(Integer)
          [:integer, value.to_s]
        elsif value_class.equal?(Float)
          [:float, [value].pack("G")]
        elsif value_class.equal?(BigDecimal)
          canonical_big_decimal(value)
        elsif value_class.equal?(Date)
          canonical_date(value)
        elsif value_class.equal?(Time)
          canonical_time(value)
        elsif value_class.equal?(Array)
          canonical_array(value, active)
        elsif value_class.equal?(Hash)
          canonical_hash(value, active)
        else
          raise InvalidStateError, "unsupported candidate value"
        end
      end

      def plain_record?(candidate)
        Object.instance_method(:instance_of?).bind_call(candidate, Engram::Record) &&
          !custom_behavior?(candidate, Engram::Record)
      rescue TypeError
        false
      end

      def validate_detachable_record!(candidate)
        is_record = Object.instance_method(:is_a?).bind_call(candidate, Engram::Record)
        raise InvalidStateError, "candidate must be an Engram::Record" unless is_record

        instance_variables = Object.instance_method(:instance_variables).bind_call(candidate)
        unless instance_variables.sort == RECORD_INSTANCE_VARIABLES.sort
          raise InvalidStateError, "candidate Record must have exactly the expected instance variables"
        end

        if Object.instance_method(:instance_of?).bind_call(candidate, Engram::Record) && !plain_record?(candidate)
          raise InvalidStateError, "candidate must be a plain Engram::Record"
        end
      rescue TypeError
        raise InvalidStateError, "candidate must be an Engram::Record"
      end

      def plain_class(value)
        Object.instance_method(:class).bind_call(value)
      rescue TypeError
        raise InvalidStateError, "unsupported candidate value"
      end

      def custom_behavior?(value, value_class)
        singleton_class = begin
          Object.instance_method(:singleton_class).bind_call(value)
        rescue TypeError
          return false
        end
        return false if singleton_class.equal?(value_class)

        method_visibilities = %i[
          public_instance_methods protected_instance_methods private_instance_methods
        ]
        return true if method_visibilities.any? do |visibility|
          Module.instance_method(visibility).bind_call(singleton_class, false).any?
        end

        singleton_ancestors = Module.instance_method(:ancestors).bind_call(singleton_class)
        class_ancestors = Module.instance_method(:ancestors).bind_call(value_class)
        return true unless singleton_ancestors.length == class_ancestors.length + 1 &&
          class_ancestors.each_with_index.all? { |ancestor, index| singleton_ancestors[index + 1].equal?(ancestor) }

        method_visibilities.any? do |visibility|
          singleton_methods = Module.instance_method(visibility).bind_call(singleton_class, true)
          class_methods = Module.instance_method(visibility).bind_call(value_class, true)
          singleton_methods.length != class_methods.length ||
            singleton_methods.any? { |method_name| !class_methods.include?(method_name) }
        end
      end

      def canonical_date(value)
        start = Date.instance_method(:start).bind_call(value)
        [:date, identity(value), frozen?(value),
          Date.instance_method(:jd).bind_call(value), canonical_date_start(start)]
      end

      def canonical_date_start(value)
        value_class = Object.instance_method(:class).bind_call(value)
        return [:float, [value].pack("G")] if value_class.equal?(Float)
        return [:integer, value.to_s] if value_class.equal?(Integer)

        raise InvalidStateError, "unsupported Date start #{value_class}"
      end

      def canonical_big_decimal(value)
        sign, digits, base, exponent = BigDecimal.instance_method(:split).bind_call(value)
        [:big_decimal, sign, String.instance_method(:b).bind_call(digits), base, exponent]
      end

      def canonical_time(value)
        exact_value = Time.instance_method(:to_r).bind_call(value)
        components = Time.instance_method(:to_a).bind_call(value)
        [:time,
          identity(value),
          frozen?(value),
          Time.instance_method(:to_i).bind_call(value),
          Time.instance_method(:nsec).bind_call(value),
          Rational.instance_method(:numerator).bind_call(exact_value),
          Rational.instance_method(:denominator).bind_call(exact_value),
          Time.instance_method(:utc_offset).bind_call(value),
          Time.instance_method(:utc?).bind_call(value),
          components.map { |component| canonical_time_component(component) }]
      end

      def canonical_time_component(value)
        value_class = Object.instance_method(:class).bind_call(value)
        if value_class.equal?(NilClass)
          [:nil]
        elsif value_class.equal?(TrueClass) || value_class.equal?(FalseClass)
          [:boolean, value]
        elsif value_class.equal?(String)
          [:string, String.instance_method(:encoding).bind_call(value), String.instance_method(:b).bind_call(value)]
        elsif value_class.equal?(Integer)
          [:integer, value.to_s]
        else
          raise InvalidStateError, "unsupported Time component #{value_class}"
        end
      end

      def canonical_array(value, active)
        with_acyclic_value(value, active) do
          elements = []
          Array.instance_method(:each).bind_call(value) do |element|
            elements << canonical_value(element, active)
          end
          [:array, identity(value), frozen?(value), elements]
        end
      end

      def canonical_hash(value, active)
        default_proc = Hash.instance_method(:default_proc).bind_call(value)
        raise InvalidStateError, "unsupported candidate value Hash with a default proc" if default_proc

        with_acyclic_value(value, active) do
          entries = []
          Hash.instance_method(:each_pair).bind_call(value) do |key, nested_value|
            entries << [canonical_value(key, active), canonical_value(nested_value, active)]
          end
          default = Hash.instance_method(:default).bind_call(value)
          compare_by_identity = Hash.instance_method(:compare_by_identity?).bind_call(value)
          [:hash, identity(value), frozen?(value), compare_by_identity,
            canonical_value(default, active), entries]
        end
      end

      def frozen?(value)
        Object.instance_method(:frozen?).bind_call(value)
      end

      def identity(value)
        IdentityToken.new(value)
      end

      def with_acyclic_value(value, active)
        raise InvalidStateError, "unsupported cyclic candidate value" if active.key?(value)

        active[value] = true
        yield
      ensure
        active.delete(value)
      end
    end
  end
end
