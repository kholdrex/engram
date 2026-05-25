# frozen_string_literal: true

module Engram
  # Background observation: runs extract → consolidate off the request path.
  # Defined only when ActiveJob is available (loaded via the Railtie).
  class ObserveJob < ActiveJob::Base
    def perform(scope, messages)
      Engram::Memory.new(scope: scope).observe(messages)
    end
  end
end
