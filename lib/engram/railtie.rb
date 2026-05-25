# frozen_string_literal: true

require "rails/railtie"

module Engram
  # Wires engram into Rails: the `has_memory` macro on ActiveRecord models and the
  # background ObserveJob on ActiveJob. Loaded only when Rails is present (see lib/engram.rb).
  class Railtie < ::Rails::Railtie
    initializer "engram.active_record" do
      ActiveSupport.on_load(:active_record) do
        require "engram/rails/has_memory"
        extend Engram::Rails::HasMemory
      end
    end

    initializer "engram.active_job" do
      ActiveSupport.on_load(:active_job) do
        require "engram/rails/observe_job"
      end
    end
  end
end
