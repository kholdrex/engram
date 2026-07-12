# frozen_string_literal: true

require "digest"
require "securerandom"

module Engram
  module Rails
    # Claims use atomic unless-exist writes. Generic ActiveSupport caches do not expose
    # compare-and-delete, so release leaves a claim in place until lease expiry and completion
    # never deletes it.
    class CacheProcessedTurns
      include Engram::Ports::ProcessedTurns

      class NonAtomicCacheError < Engram::Error; end
      class CacheWriteError < Engram::Error; end

      def initialize(namespace: "engram:processed_turns", ttl: 86_400, lease_ttl: 300, cache: ::Rails.cache)
        @namespace = namespace
        @ttl = ttl
        @lease_ttl = lease_ttl
        @cache = cache
      end

      def claim(scope:, key:)
        return if completed?(scope: scope, key: key)
        token = SecureRandom.uuid
        result = @cache.write(claim_key(scope, key), token, expires_in: @lease_ttl, unless_exist: true)
        unless result == true || result == false
          raise NonAtomicCacheError, "cache backend must return true/false for atomic write(unless_exist: true)"
        end
        return unless result
        return token unless completed?(scope: scope, key: key)

        release(scope: scope, key: key, claim: token)
        nil
      end

      def complete(scope:, key:, claim:)
        written = @cache.write(completed_key(scope, key), true, expires_in: @ttl)
        raise CacheWriteError, "cache backend failed to write completed observation" unless written
        true
      end

      def release(scope:, key:, claim:)
        # A read followed by delete could delete a successor lease.
        nil
      end

      def completed?(scope:, key:)
        @cache.exist?(completed_key(scope, key))
      end

      private

      def digest(scope, key)
        encoded = [scope, key].each_with_object(+"") do |component, buffer|
          bytes = component.to_s.encode(Encoding::UTF_8)
          buffer << [bytes.bytesize].pack("N") << bytes
        end
        Digest::SHA256.hexdigest(encoded)
      end

      def claim_key(scope, key)
        "#{@namespace}:claim:#{digest(scope, key)}"
      end

      def completed_key(scope, key)
        "#{@namespace}:completed:#{digest(scope, key)}"
      end
    end
  end
end
