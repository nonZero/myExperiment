# myExperiment: db/migrate/090_adjust_pictures.rb
#
# Copyright (c) 2007 University of Manchester and the University of Southampton.
# See license.txt for details.

class AdjustPictures < ActiveRecord::Migration
  def self.up

    conn = ActiveRecord::Base.connection

    # collect all the file_column paths

    workflow_image         = {}
    workflow_svg           = {}
    workflow_version_image = {}
    workflow_version_svg   = {}

    Workflow.find(:all, :select => 'id, image AS image_fc, svg AS svg_fc').each do |workflow|
      workflow_image[workflow.id] = workflow.image_fc
      workflow_svg[workflow.id]   = workflow.svg_fc
    end

    WorkflowVersion.find(:all, :select => 'id, image AS image_fc, svg AS svg_fc').each do |workflow_version|
      workflow_version_image[workflow_version.id] = workflow_version.image_fc
      workflow_version_svg[workflow_version.id]   = workflow_version.svg_fc
    end

    # save the previews into the database

    Workflow.find(:all).each do |workflow|

      if workflow_image[workflow.id] || workflow_svg[workflow.id]

        if workflow_image[workflow.id]
          workflow.image = File.new("public/workflow/image/#{workflow.id}/#{workflow_image[workflow.id]}").read
        end

        if workflow_svg[workflow.id]
          workflow.svg = File.new("public/workflow/svg/#{workflow.id}/#{workflow_svg[workflow.id]}").read
        end

        workflow.preview.save
        conn.execute("UPDATE workflows SET preview_id = #{workflow.preview.id} WHERE id = #{workflow.id}")
      end
    end
      
    WorkflowVersion.find(:all).each do |workflow_version|

      if workflow_version_image[workflow_version.id] || workflow_version_svg[workflow_version.id]

        if workflow_version_image[workflow_version.id]
          workflow_version.image = File.new("public/workflow/version/image/#{workflow_version.id}/#{workflow_version_image[workflow_version.id]}").read
        end

        if workflow_version_svg[workflow_version.id]
          workflow_version.svg = File.new("public/workflow/version/svg/#{workflow_version.id}/#{workflow_version_svg[workflow_version.id]}").read
        end

        workflow_version.preview.save
        conn.execute("UPDATE workflow_versions SET preview_id = #{workflow_version.preview.id} WHERE id = #{workflow_version.id}")
      end
    end
  end

  def self.down
  end
end
