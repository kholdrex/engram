# frozen_string_literal: true

module Engram
  module Adapters
    # In-process ProcessedTurns. The zero-config default; guards against double-processing
    # within a single process. For cross-process/retry durability in Rails, use a persistent
    # adapter such as Rails::CacheProcessedTurns.
    class InMemoryProcessedTurns
      include Ports::ProcessedTurns

      def initialize(lease_ttl: 300, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @lease_ttl = lease_ttl
        @clock = clock
        @claims = {}
        @completed = Set.new
        @mutex = Mutex.new
      end

      def claim(scope:, key:)
        scoped_key = [scope, key]
        @mutex.synchronize do
          return if @completed.include?(scoped_key)
          live = @claims[scoped_key]
          return if live && live.last > @clock.call

          token = Object.new
          @claims[scoped_key] = [token, @clock.call + @lease_ttl]
          token
        end
      end

      def complete(scope:, key:, claim:)
        @mutex.synchronize do
          scoped_key = [scope, key]
          return false unless @claims.dig(scoped_key, 0).equal?(claim)
          @completed << scoped_key
          @claims.delete(scoped_key)
          true
        end
      end

      def release(scope:, key:, claim:)
        @mutex.synchronize do
          scoped_key = [scope, key]
          @claims.delete(scoped_key) if @claims.dig(scoped_key, 0).equal?(claim)
        end
      end

      def completed?(scope:, key:)
        @mutex.synchronize { @completed.include?([scope, key]) }
      end

      def clear
        @mutex.synchronize do
          @claims.clear
          @completed.clear
        end
      end
    end
  end
end
