# frozen_string_literal: true

module Engram
  module Ports
    # PLACEHOLDER (v0.2). Contract for deriving candidate facts from a conversation turn.
    # Declared now so the differentiator (extract -> consolidate) slots in without
    # reworking the core. Not implemented in v0.1.
    module Extractor
      # Given conversation messages, return an Array whose members are Record or Extraction values.
      def extract(messages:, scope:)
        raise NotImplementedError, "Extractor arrives in v0.2"
      end
    end
  end
end
