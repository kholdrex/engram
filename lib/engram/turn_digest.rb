# frozen_string_literal: true

require "digest"
require "json"

module Engram
  # Produces a stable digest for a conversation turn (scope + messages). Used as an
  # idempotency key so the same turn is not observed twice.
  module TurnDigest
    module_function

    def digest(scope:, messages:)
      normalized = Array(messages).map { |message| normalize(message) }
      Digest::SHA256.hexdigest(JSON.generate(scope: scope, messages: normalized))
    end

    def normalize(message)
      if message.is_a?(Hash)
        {
          role: (message[:role] || message["role"] || "user").to_s,
          content: (message[:content] || message["content"]).to_s
        }
      else
        {role: "user", content: message.to_s}
      end
    end
  end
end
