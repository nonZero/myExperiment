##
##
## myExperiment - a social network for scientists
##
## Copyright (C) 2007 University of Manchester/University of Southampton
##
## This program is free software; you can redistribute it and/or modify
## it under the terms of the GNU Affero General Public License
## as published by the Free Software Foundation; either version 3 of the
## License, or (at your option) any later version.
##
## This program is distributed in the hope that it will be useful,
## but WITHOUT ANY WARRANTY; without even the implied warranty of
## MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
## GNU Affero General Public License for more details.
##
## You should have received a copy of the GNU Affero General Public License
## along with this program; if not, see http://www.gnu.org/licenses
## or write to the Free Software Foundation,Inc., 51 Franklin Street,
## Fifth Floor, Boston, MA 02110-1301  USA
##
##

module Mib
  module Acts #:nodoc:
    module Contributor #:nodoc:
      def self.included(mod)
        mod.extend(ClassMethods)
      end

      module ClassMethods
        def acts_as_contributor
          has_many :contributions,
                   :as => :contributor,
                   :order => "contributable_type ASC, created_at DESC",
                   :dependent => :destroy

          has_many :policies,
                   :as => :contributor,
                   :order => "created_at DESC",
                   :dependent => :destroy

          has_many :permissions,
                   :as => :contributor,
                   :dependent => :destroy

          # before_destroy do |c|
          #   c.contributables.each do |contributable|
          #     # ABSOLUTLY NOTHING!!
          #     # it is important that contributables are left in the database.
          #     # that way, the dba can always retrieve them at a later date!
          #   end
          # end

          class_eval do
            extend Mib::Acts::Contributor::SingletonMethods
          end
          include Mib::Acts::Contributor::InstanceMethods
        end
      end

      module SingletonMethods
      end

      module InstanceMethods
        def contributables
          rtn = []
          
          Contribution.find_all_by_contributor_id_and_contributor_type(self.id, self.class.to_s, { :order => "contributable_type ASC, contributable_id ASC" }).each do |c|
            # rtn << c.contributable_type.classify.constantize.find(c.contributable_id)
            rtn << c.contributable
          end

          return rtn
        end

        # this method is called by the Policy instance when authorizing protected attributes.
        def protected?(other)
          # extend in instance class
          false
        end
        
        # first method in the authorization chain
        # Mib::Acts::Contributor.authorized? --> Mib::Acts::Contributable.authorized? --> Contribution.authorized? --> Policy.authorized? --> Permission[s].authorized? --> true / false
        def authorized?(action_name, contributable)
          if contributable.kind_of? Mib::Acts::Contributable
            return contributable.authorized?(action_name, self)
          else
            return false
          end
        end
  
        def contribution_tags
          tags = contribution_tags!
          
          rtn = []
          
          tags.each { |key, value|
            rtn << value
          }
          
          return rtn
        end
        
        def collection_contribution_tags(collection)
          tags = collection_contribution_tags!(collection)
          
          rtn = []
          
          tags.each { |key, value|
            rtn << value
          }
          
          return rtn
        end
        
        def tag_list
          rtn = StringIO.new
          
          self.contribution_tags.each do |t|
            rtn << t.name
            rtn << " "
          end
          
          return rtn.string
        end
        
protected
        
        def collection_contribution_tags!(collection)
          tags = { }
          
          collection.each do |contributor|
            contributor.contribution_tags!.each { |key, value|
              if tags.key? key
                tags[key].taggings_count = tags[key].taggings_count.to_i + value.taggings_count.to_i
              else
                tags[key] = Tag.new(:name => key, :taggings_count => value.taggings_count)
              end
            }
          end
          
          return tags
        end
  
        def contribution_tags!
          tags = {}
          
          self.contributions.each do |c|
            c.contributable.tags.each do |t|
              if tags.key? t.name
                tags[t.name].taggings_count = tags[t.name].taggings_count.to_i + 1
              else
                tags[t.name] = Tag.new(:name => t.name, :taggings_count => 1)
              end
            end
          end
          
          return tags
        end
      
      end
    end
  end
end

ActiveRecord::Base.class_eval do
  include Mib::Acts::Contributor
end
