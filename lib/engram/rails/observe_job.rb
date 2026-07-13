# frozen_string_literal: true

module Engram
  # Background observation: runs extract → consolidate off the request path.
  # Defined only when ActiveJob is available (loaded via the Railtie).
  class ObserveJob < ActiveJob::Base
    # An in-progress claim clears only when its lease expires, so back off polynomially:
    # waits of ~3s, 18s, 83s, 258s, 627s, ... comfortably outlast the default 300s
    # lease_ttl before attempts run out.
    retry_on Engram::ObservationInProgressError,
      wait: ->(executions) { (executions**4) + 2 },
      attempts: 8

    def perform(scope, messages)
      Engram::Memory.new(scope: scope).observe(messages)
    end
  end
end
