# frozen_string_literal: true

module Engram
  module Adapters
    # Embedder backed by RubyLLM. Requires the host app to add the `ruby_llm` gem and
    # configure its credentials. Referenced only at call time, so engram loads without it.
    class RubyLLMEmbedder
      include Ports::Embedder

      DEFAULT_MODEL = "text-embedding-3-small"
      DEFAULT_DIMENSIONS = 1536

      def initialize(model: DEFAULT_MODEL, dimensions: nil)
        @model = model
        @requested_dimensions = dimensions
        @dimensions = dimensions || DEFAULT_DIMENSIONS
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
        vectors = request_embedding(text)
        validate_dimensions!(vectors)
        vectors
      end

      private

      def ensure_ruby_llm!
        return if defined?(RubyLLM)

        raise Engram::Error,
          "RubyLLMEmbedder requires the `ruby_llm` gem. Add it to your Gemfile and configure it."
      end

      # Explicitly configured dimensions are requested from the provider (models that
      # support shortening, like text-embedding-3-*, honor this). The kwarg is skipped on
      # RubyLLM versions that predate it; validation below still catches the mismatch.
      def request_embedding(text)
        if @requested_dimensions && embed_accepts_dimensions?
          RubyLLM.embed(text, model: @model, dimensions: @requested_dimensions).vectors
        else
          RubyLLM.embed(text, model: @model).vectors
        end
      end

      def embed_accepts_dimensions?
        RubyLLM.method(:embed).parameters.any? do |type, name|
          type == :keyrest || ([:key, :keyreq].include?(type) && name == :dimensions)
        end
      end

      def validate_dimensions!(vectors)
        length = vectors.respond_to?(:length) ? vectors.length : nil
        return if length == @dimensions

        raise Engram::Error,
          "embedding model #{@model.inspect} returned #{length ? "#{length}-dimension" : "non-vector"} output " \
            "but the embedder is configured with dimensions: #{@dimensions}; align the dimensions option " \
            "(and your vector column) with the model's output"
      end
    end
  end
end
