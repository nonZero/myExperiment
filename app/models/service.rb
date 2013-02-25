# myExperiment: app/models/service.rb
#
# Copyright (c) 2007 University of Manchester and the University of Southampton.
# See license.txt for details.

require 'acts_as_site_entity'
require 'acts_as_contributable'
require 'sunspot_rails'

class Service < ActiveRecord::Base
  acts_as_site_entity
  acts_as_contributable

  has_many :service_categories
  has_many :service_types
  has_many :service_tags
  has_many :service_deployments

  if Conf.solr_enable
    searchable do
      text :submitter_label
      text :name
      text :provider_label
      text :endpoint
      text :wsdl
      text :city
      text :country
      text :description

      text :categories do
        service_categories.map do |category| category.label end
      end

      text :tags do
        service_tags.map do |tag| tag.label end
      end

      text :types do
        service_types.map do |types| types.label end
      end
    end
  end
end
