# frozen_string_literal: true

module Engram
  # Background observation: runs extract → consolidate off the request path.
  # Defined only when ActiveJob is available (loaded via the Railtie).
  class ObserveJob < ActiveJob::Base
    # Later retries must outlast the default claim lease.
    retry_on Engram::ObservationInProgressError,
      wait: ->(executions) { (executions**4) + 2 },
      attempts: 8

    def perform(scope, messages)
      Engram::Memory.new(scope: scope).observe(messages)
    end
  end
end
