# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module Engram
  module Generators
    # `bin/rails generate engram:install [--dimensions=1536]`
    # Creates the migration, an initializer, and the AR model.
    class InstallGenerator < ::Rails::Generators::Base
      include ::Rails::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      DEFAULT_DIMENSIONS = 1536

      class_option :dimensions, type: :numeric, default: DEFAULT_DIMENSIONS,
        desc: "Embedding dimensions (match your embedding model)"

      def create_migration_file
        migration_template "create_engram_memories.rb.tt",
          "db/migrate/create_engram_memories.rb"
      end

      def create_initializer
        template "initializer.rb.tt", "config/initializers/engram.rb"
      end

      def create_model
        template "memory_record.rb.tt", "app/models/engram/memory_record.rb"
      end

      def self.next_migration_number(dir)
        ::ActiveRecord::Generators::Base.next_migration_number(dir)
      end

      private

      def dimensions
        options[:dimensions]
      end

      def migration_version
        "#{::ActiveRecord::VERSION::MAJOR}.#{::ActiveRecord::VERSION::MINOR}"
      end
    end
  end
end
