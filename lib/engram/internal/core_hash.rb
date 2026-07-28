# frozen_string_literal: true

module Engram
  module Internal
    # Iterates a Hash's stored (key, value) pairs without dispatching through the
    # hash's own overridden methods and without provoking per-key #hash/#eql?.
    #
    # Bound Hash#each_pair was chosen elsewhere to bypass a Hash subclass's
    # overridden traversal. It is not enough on its own: on Ruby 3.4 a hash left in
    # a delete-then-insert collision state can invoke a *key's* #eql? during plain
    # iteration (Hash#each_pair / #to_a), which would let a malicious String-subclass
    # key run application code inside code that must stay behavior-free. Bound #keys
    # and #values return the stored key and value objects in matching insertion order
    # without comparing keys, so zipping them by position reconstructs every pair
    # with no application dispatch.
    module CoreHash
      KEYS = ::Hash.instance_method(:keys)
      VALUES = ::Hash.instance_method(:values)
      private_constant :KEYS, :VALUES

      module_function

      def each_pair(hash)
        keys = KEYS.bind_call(hash)
        values = VALUES.bind_call(hash)
        index = 0
        count = keys.length
        while index < count
          yield keys[index], values[index]
          index += 1
        end
        hash
      end
    end
  end
end
