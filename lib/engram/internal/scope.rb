# frozen_string_literal: true

module Engram
  module Internal
    # Compares Record scopes without dispatching through application-defined readers
    # or equality methods. Keep orchestration preflight and persistence enforcement on
    # the same fail-closed rules.
    module Scope
      RECORD_SCOPE_READER = Engram::Record.instance_method(:scope)

      module_function

      def record_matches?(record, expected_scope)
        same?(RECORD_SCOPE_READER.bind_call(record), expected_scope)
      rescue TypeError
        false
      end

      def same?(actual_scope, expected_scope)
        actual_class = Object.instance_method(:class).bind_call(actual_scope)
        expected_class = Object.instance_method(:class).bind_call(expected_scope)
        return true if actual_class.equal?(NilClass) && expected_class.equal?(NilClass)
        return false unless actual_class.equal?(String) && expected_class.equal?(String)

        String.instance_method(:==).bind_call(actual_scope, expected_scope)
      rescue TypeError
        false
      end
    end
  end
end
