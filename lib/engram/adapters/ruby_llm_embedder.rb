# frozen_string_literal: true

module Engram
  module Adapters
    # Embedder backed by RubyLLM. Requires the host app to add the `ruby_llm` gem and
    # configure its credentials. Referenced only at call time, so engram loads without it.
    class RubyLLMEmbedder
      include Ports::Embedder

      DEFAULT_MODEL = "text-embedding-3-small"
      DEFAULT_DIMENSIONS = 1536

      def initialize(model: DEFAULT_MODEL, dimensions: DEFAULT_DIMENSIONS)
        @model = model
        @dimensions = dimensions
      end

      attr_reader :dimensions, :model

      def embedding_metadata
        Engram::EmbeddingMetadata.build(
          adapter: self.class.name,
          provider: "ruby_llm",
          model: model,
          dimensions: dimensions
        )
      end

      def embed(text)
        ensure_ruby_llm!
        RubyLLM.embed(text, model: @model).vectors
      end

      private

      def ensure_ruby_llm!
        return if defined?(RubyLLM)

        raise Engram::Error,
          "RubyLLMEmbedder requires the `ruby_llm` gem. Add it to your Gemfile and configure it."
      end
    end
  end
end
