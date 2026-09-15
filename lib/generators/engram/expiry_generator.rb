# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module Engram
  module Generators
    # Adds expiry to a table created by Engram 0.7 or earlier.
    class ExpiryGenerator < ::Rails::Generators::Base
      include ::Rails::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      def create_migration_file
        migration_template "add_expiry_to_engram_memories.rb.tt",
          "db/migrate/add_expiry_to_engram_memories.rb"
      end

      def self.next_migration_number(dir)
        ::ActiveRecord::Generators::Base.next_migration_number(dir)
      end

      private

      def migration_version
        "#{::ActiveRecord::VERSION::MAJOR}.#{::ActiveRecord::VERSION::MINOR}"
      end
    end
  end
end
