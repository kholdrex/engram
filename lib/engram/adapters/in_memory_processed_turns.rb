# frozen_string_literal: true

module Engram
  module Adapters
    # In-process ProcessedTurns. The zero-config default; guards against double-processing
    # within a single process. For cross-process/retry durability in Rails, use a persistent
    # adapter such as Rails::CacheProcessedTurns.
    class InMemoryProcessedTurns
      include Ports::ProcessedTurns

      def initialize
        @keys = Set.new
      end

      def seen?(key)
        @keys.include?(key)
      end

      def record(key)
        @keys << key
        key
      end

      def clear
        @keys.clear
      end
    end
  end
end
