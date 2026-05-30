# frozen_string_literal: true

module Engram
  # Optional ActiveSupport::Notifications integration.
  #
  # Engram core remains dependency-free: when ActiveSupport is not loaded, instrumentation
  # is a no-op around the supplied block.
  module Instrumentation
    module_function

    def instrument(event, payload = {})
      started_at = monotonic_time

      unless notifications?
        return yield if block_given?
        return nil
      end

      ActiveSupport::Notifications.instrument("#{event}.engram", payload) do
        yield if block_given?
      ensure
        payload[:duration_ms] = elapsed_ms(started_at)
      end
    end

    def payload(scope: nil, store: nil, **attributes)
      attributes = attributes.compact
      attributes[:store_adapter] = adapter_name(store) if store
      scope_identifier = scope_identifier(scope)
      attributes[:scope_identifier] = scope_identifier if scope_identifier
      attributes
    end

    def notifications?
      defined?(ActiveSupport::Notifications) && ActiveSupport::Notifications.respond_to?(:instrument)
    end

    def adapter_name(adapter)
      adapter.class.name || adapter.class.to_s
    end

    def scope_identifier(scope)
      formatter = Engram.config.instrumentation_scope_identifier
      return nil unless formatter

      formatter.respond_to?(:call) ? formatter.call(scope) : scope.to_s
    end

    def elapsed_ms(started_at)
      ((monotonic_time - started_at) * 1000).round(1)
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
