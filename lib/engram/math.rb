# frozen_string_literal: true

module Engram
  # Small vector helpers shared by adapters and consolidators.
  module Math
    module_function

    def cosine_similarity(a, b)
      return 0.0 if a.nil? || b.nil? || a.empty? || b.empty? || a.length != b.length

      dot = 0.0
      norm_a = 0.0
      norm_b = 0.0
      a.each_index do |i|
        dot += a[i] * b[i]
        norm_a += a[i]**2
        norm_b += b[i]**2
      end
      denom = ::Math.sqrt(norm_a) * ::Math.sqrt(norm_b)
      denom.zero? ? 0.0 : dot / denom
    end
  end
end
