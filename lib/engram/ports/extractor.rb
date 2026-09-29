# frozen_string_literal: true

module Engram
  module Ports
    # Contract for deriving candidate facts from a conversation turn.
    # Implementation: Extractors::LLMExtractor.
    module Extractor
      # Given conversation messages, return an Array whose members are Record or Extraction values.
      def extract(messages:, scope:)
        raise NotImplementedError, "#{self.class} must implement #extract"
      end
    end
  end
end
