# frozen_string_literal: true

require "digest"

module Engram
  module Adapters
    # Deterministic, network-free embedder for tests and the zero-config default.
    # NOT semantic — equal text yields equal vectors, but unrelated text is not
    # meaningfully close. Good enough to exercise the pipeline; useless for quality.
    class NullEmbedder
      include Ports::Embedder

      def initialize(dimensions: 16)
        @dimensions = dimensions
      end

      attr_reader :dimensions

      def embed(text)
        seed = Digest::SHA256.hexdigest(text.to_s)
        Array.new(@dimensions) do |i|
          byte = seed[(i * 2) % seed.length, 2].to_i(16)
          (byte / 255.0) * 2 - 1 # map 0..255 -> -1.0..1.0
        end
      end
    end
  end
end
