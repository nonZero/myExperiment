# myExperiment: lib/acts_as_runner.rb
#
# Copyright (c) 2007 University of Manchester and the University of Southampton.
# See license.txt for details.

module Jits
  module Acts #:nodoc:
    module Runner #:nodoc:
      def self.included(mod)
        mod.extend(ClassMethods)
      end

      module ClassMethods
        def acts_as_runnable
          has_many :jobs,
                   :as => :runner,
                   :order => "updated_at DESC"

          class_eval do
            extend Jits::Acts::Runner::SingletonMethods
          end
          include Jits::Acts::Runner::InstanceMethods
        end
      end

      module SingletonMethods
      end

      module InstanceMethods
        # TODO: abstract out the set of methods that define a contract for a runner and declare them here.
        # to be overridden in the specialised model object.
      end
    end
  end
end

ActiveRecord::Base.class_eval do
  include Jits::Acts::Runner
end