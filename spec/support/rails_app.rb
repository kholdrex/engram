# frozen_string_literal: true

# Minimal Rails application used only by the :integration specs. Booting a real app is what
# makes engram's Railtie initializers run, which is the whole point: the Railtie wires
# `has_memory` onto ActiveRecord and loads ObserveJob onto ActiveJob. Loading just the gem
# (as the offline suite does) never exercises that path.
#
# Schema creation lives in the integration spec's before(:all) so each example group sets up
# and tears down its own tables; this file only boots the app and declares the models.

require "rails"
require "active_record/railtie"
require "active_job/railtie"
require "neighbor"
require "logger"

require "engram"
# spec_helper requires "engram" before Rails is loaded, so the conditional railtie require in
# lib/engram.rb is skipped. Load it explicitly now that Rails::Railtie exists.
require "engram/railtie"

ENV["DATABASE_URL"] ||= "postgres://postgres:postgres@localhost:5432/engram_test"

module EngramDummy
  class Application < ::Rails::Application
    config.eager_load = false
    config.logger = ::Logger.new(IO::NULL)
    config.active_job.queue_adapter = :inline
    config.cache_store = :memory_store
    config.secret_key_base = "engram-integration-tests"
  end
end

Rails.application.initialize! unless Rails.application.initialized?

# establish_connection loads ActiveRecord::Base, firing the Railtie's on_load(:active_record)
# hook that extends `has_memory` onto models. Reading the ActiveJob adapter does the same for
# on_load(:active_job), which is what defines Engram::ObserveJob.
ActiveRecord::Base.establish_connection(ENV.fetch("DATABASE_URL"))
ActiveJob::Base.queue_adapter

class ApplicationRecord < ActiveRecord::Base
  self.abstract_class = true
end

module Engram
  # The model the install generator would create. PgvectorStore resolves to it by default.
  class MemoryRecord < ApplicationRecord
    self.table_name = "engram_memories"
    has_neighbors :embedding
  end
end

# A stand-in for a host app's User, wired with the macro the Railtie installs.
class User < ApplicationRecord
  has_memory
end
