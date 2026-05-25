# frozen_string_literal: true

module Engram
  module Adapters
    # Completion backed by RubyLLM structured output. Requires the host app to add the
    # `ruby_llm` gem and configure credentials. Referenced only at call time.
    #
    # NOTE: exercised via integration tests, not the unit suite (which uses FakeCompletion).
    class RubyLLMCompletion
      include Ports::Completion

      def initialize(model: nil)
        @model = model
      end

      def complete(system:, user:, schema:)
        ensure_ruby_llm!
        chat = @model ? RubyLLM.chat(model: @model) : RubyLLM.chat
        chat.with_instructions(system) if system
        response = chat.with_schema(schema).ask(user)
        coerce(response.content)
      end

      private

      def coerce(content)
        return content if content.is_a?(Hash)

        require "json"
        JSON.parse(content)
      rescue JSON::ParserError => e
        raise Engram::Error, "RubyLLMCompletion expected structured output: #{e.message}"
      end

      def ensure_ruby_llm!
        return if defined?(RubyLLM)

        raise Engram::Error,
          "RubyLLMCompletion requires the `ruby_llm` gem. Add it to your Gemfile and configure it."
      end
    end
  end
end
