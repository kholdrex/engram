# frozen_string_literal: true

module Engram
  module Ports
    # Contract for turning text into a vector embedding.
    # Implementations: Adapters::NullEmbedder, Adapters::RubyLLMEmbedder.
    module Embedder
      # Return an Array<Float> embedding for `text`.
      def embed(text)
        raise NotImplementedError, "#{self.class} must implement #embed"
      end

      # Dimensionality of the produced vectors.
      def dimensions
        raise NotImplementedError, "#{self.class} must implement #dimensions"
      end
    end
  end
end
