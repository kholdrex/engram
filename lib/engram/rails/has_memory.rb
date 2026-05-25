# frozen_string_literal: true

module Engram
  module Rails
    # Class-level macro added to ActiveRecord models.
    #
    #   class User < ApplicationRecord
    #     has_memory                      # scope => "user:<id>"
    #   end
    #
    #   class Account < ApplicationRecord
    #     has_memory scope: ->{ "team:#{team_id}" }
    #   end
    #
    # `user.memory` returns an Engram::Memory bound to that owner.
    module HasMemory
      def has_memory(scope: nil)
        scope_proc = scope

        define_method(:memory) do
          key =
            if scope_proc
              instance_exec(&scope_proc)
            else
              "#{self.class.name.underscore}:#{id}"
            end
          Engram::Memory.new(scope: key)
        end
      end
    end
  end
end
