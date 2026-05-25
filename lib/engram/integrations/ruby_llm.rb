# frozen_string_literal: true

module Engram
  module Integrations
    module RubyLLM
      # Wraps a RubyLLM chat so every `ask` is preceded by recall + inject.
      # Experimental in v0.1 — surface may change as the RubyLLM integration matures.
      #
      #   chat = Engram.with_memory(RubyLLM.chat, memory: current_user.memory)
      #   chat.ask("why am I rate limited?")  # recall + inject happen automatically
      class MemoryChat
        def initialize(chat, memory:, limit: Engram.config.default_limit)
          @chat = chat
          @memory = memory
          @limit = limit
        end

        def ask(message, **opts)
          augmented = @memory.inject_into(message.to_s, query: message.to_s, limit: @limit)
          @chat.ask(augmented, **opts)
        end

        def method_missing(name, *args, **kwargs, &block)
          return super unless @chat.respond_to?(name)

          @chat.public_send(name, *args, **kwargs, &block)
        end

        def respond_to_missing?(name, include_private = false)
          @chat.respond_to?(name, include_private) || super
        end
      end
    end
  end

  # Convenience entrypoint.
  def self.with_memory(chat, memory:, limit: config.default_limit)
    Integrations::RubyLLM::MemoryChat.new(chat, memory: memory, limit: limit)
  end
end
