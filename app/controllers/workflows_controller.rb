# myExperiment: app/controllers/workflows_controller.rb
#
# Copyright (c) 2007 University of Manchester and the University of Southampton.
# See license.txt for details.

require 'rdf'
require 'wf4ever/rosrs_client'

class WorkflowsController < ApplicationController

  include ApplicationHelper

  before_filter :login_required, :except => [:index, :show, :download, :named_download, :galaxy_tool, :galaxy_tool_download, :statistics, :launch, :search, :auto_complete]
  
  before_filter :store_callback, :only => [:index, :search]
  before_filter :find_workflows_rss, :only => [:index]
  before_filter :find_workflow_auth, :except => [:search, :index, :new, :create, :auto_complete]
  
  before_filter :initiliase_empty_objects_for_new_pages, :only => [:new, :create, :new_version, :create_version]
  before_filter :set_sharing_mode_variables, :only => [:show, :new, :create, :edit, :update]
  
  before_filter :check_file_size, :only => [:create, :create_version]
  before_filter :check_custom_workflow_type, :only => [:create, :create_version]
  
  before_filter :check_is_owner, :only => [:edit, :update, :edit_annotations, :update_annotations]

  # declare sweepers and which actions should invoke them
  cache_sweeper :workflow_sweeper, :only => [ :create, :create_version, :launch, :update, :update_version, :destroy_version, :destroy ]
  cache_sweeper :download_viewing_sweeper, :only => [ :show, :download, :named_download, :galaxy_tool, :galaxy_tool_download, :launch ]
  cache_sweeper :permission_sweeper, :only => [ :create, :update, :destroy ]
  cache_sweeper :bookmark_sweeper, :only => [ :destroy, :favourite, :favourite_delete ]
  cache_sweeper :tag_sweeper, :only => [ :create, :update, :tag, :destroy ]
  cache_sweeper :comment_sweeper, :only => [ :comment, :comment_delete ]
  cache_sweeper :rating_sweeper, :only => [ :rate ]
  
  # These are provided by the Taverna gem
  require 'scufl/model'
  require 'scufl/parser'
  require 'scufl/dot'
  
  # GET /workflows;search
  def search
    redirect_to(search_path + "?type=workflows&query=" + params[:query])
  end
  
  # POST /workflows/1;favourite
  def favourite
    Bookmark.create(:user => current_user, :bookmarkable => @workflow) unless @workflow.bookmarked_by_user?(current_user)
    
    respond_to do |format|
      flash[:notice] = "You have successfully added this item to your favourites."
      format.html { redirect_to workflow_url(@workflow) }
    end
  end
  
  # DELETE /workflows/1;favourite_delete
  def favourite_delete
    @workflow.bookmarks.each do |b|
      if b.user_id == current_user.id
        b.destroy
      end
    end
    
    respond_to do |format|
      flash[:notice] = "You have successfully removed this item from your favourites."
      redirect_url = params[:return_to] ? params[:return_to] : workflow_url(@workflow)
      format.html { redirect_to redirect_url }
    end
  end
  
  # POST /workflows/1;rate
  def rate
    if @workflow.contribution.contributor_type == 'User' and @workflow.contribution.contributor_id == current_user.id
      error("You cannot rate your own workflow!", "")
    else
      Rating.delete_all(["rateable_type = ? AND rateable_id = ? AND user_id = ?", @workflow.class.to_s, @workflow.id, current_user.id])
      
      Rating.create(:rateable => @workflow, :user => current_user, :rating => params[:rating])
      
      respond_to do |format|
        format.html { 
          render :update do |page|
            page.replace_html "ratings_inner", :partial => "contributions/ratings_box_inner", :locals => { :contributable => @workflow, :controller_name => controller.controller_name }
            page.replace_html "ratings_breakdown", :partial => "contributions/ratings_box_breakdown", :locals => { :contributable => @workflow }
          end }
      end
    end
  end
  
  # POST /workflows/1;tag
  def tag

    Tag.parse(convert_tags_to_gem_format(params[:tag_list])).each do |name|
      @workflow.add_tag(name, current_user)
    end

    @workflow.tag_list = "#{@workflow.tag_list}, #{convert_tags_to_gem_format params[:tag_list]}" if params[:tag_list]
    @workflow.tags_user_id = current_user # acts_as_taggable_redux
    @workflow.tag_list = "#{@workflow.tag_list}, #{convert_tags_to_gem_format params[:tag_list]}" if params[:tag_list]
    @workflow.update_tags # hack to get around acts_as_versioned

    respond_to do |format|
      format.html { 
        render :update do |page|
          unique_tag_count = @workflow.tags.uniq.length
          page.replace_html "mini_nav_tag_link", "(#{unique_tag_count})"
          page.replace_html "tags_box_header_tag_count_span", "(#{unique_tag_count})"
          page.replace_html "tags_inner_box", :partial => "tags/tags_box_inner", :locals => { :taggable => @workflow, :owner_id => @workflow.contribution.contributor_id } 
        end  
      }
    end

    @workflow.reload
    @workflow.solr_save if Conf.solr_enable
  end
  
  # GET /workflows/1;download
  def download
    if allow_statistics_logging(@viewing_version)
      @download = Download.create(:contribution => @workflow.contribution, :user => (logged_in? ? current_user : nil), :user_agent => request.env['HTTP_USER_AGENT'], :accessed_from_site => accessed_from_website?())
    end
    
    send_data(@viewing_version.content_blob.data, :filename => @workflow.filename(@viewing_version_number), :type => @viewing_version.content_type.mime_type, :disposition => (params[:disposition] || 'attachment'))
  end
  
  # GET /workflows/:id/download/:name
  def named_download

    # check that we got the right filename for this workflow
    if params[:name] == @workflow.filename(@viewing_version_number)
      download
    else
      render :nothing => true, :status => "404 Not Found"
    end
  end

  # GET /workflows/:id/launch.whip
  def launch
    # Only allow for Taverna 1 workflows.
    if @workflow.processor_class == WorkflowProcessors::TavernaScufl
      wwf = Whip::WhipWorkflow.new()
  
      wwf.title       = @viewing_version.title
      wwf.datatype    = Whip::Taverna1DataType
      wwf.author      = @workflow.contributor_name
      wwf.name        = @workflow.filename(@viewing_version_number)
      wwf.summary     = @viewing_version.body
      wwf.version     = @viewing_version.version.to_s
      wwf.workflow_id = @workflow.id.to_s
      wwf.updated     = @viewing_version.updated_at
      wwf.data        = @viewing_version.content_blob.data
  
      dir = 'tmp/bundles'
  
      FileUtils.mkdir(dir) if not File.exists?(dir)
      file_path = Whip::filePath(wwf, dir)
  
      Whip::bundle(wwf, dir)
  
      respond_to do |format|
        format.whip { 
          send_data(File.read(file_path), :filename => "#{@viewing_version.unique_name}_#{@viewing_version.version}.whip",
              :type => "application/whip-archive", :disposition => 'inline')
        }
      end
    end
  end

  # GET /workflows/:id/versions/:version/galaxy_tool
  def galaxy_tool
  end

  # GET /workflows/:id/versions/:version/galaxy_tool_download
  def galaxy_tool_download

    if params[:server].nil? || params[:server].empty?
      flash.now[:error] = "You must provide the URL to a Taverna server."
      render(:action => :galaxy_tool, :id => @workflow.id, :version => @viewing_version_number.to_s)
      return
    end

    zip_file_name = "tmp/galaxy_tool.#{Process.pid}"

    TavernaToGalaxy.generate(@workflow, @viewing_version_number, params[:server], zip_file_name)

    zip_file = File.read(zip_file_name)
    File.unlink(zip_file_name)

    Download.create(:contribution => @workflow.contribution,
        :user               => (logged_in? ? current_user : nil),
        :user_agent         => request.env['HTTP_USER_AGENT'],
        :accessed_from_site => accessed_from_website?(),
        :kind               => 'Galaxy tool')

    send_data(zip_file,
        :filename => "#{@workflow.unique_name}_galaxy_tool.zip",
        :type => 'application/zip',
        :disposition => 'attachment')
  end

  # GET /workflows
  def index
    respond_to do |format|
      format.html do

        @pivot, problem = calculate_pivot(

            :pivot_options  => Conf.pivot_options,
            :params         => params,
            :user           => current_user,
            :search_models  => [Workflow],
            :search_limit   => Conf.max_search_size,

            :locked_filters => { 'CATEGORY' => 'Workflow' },

            :active_filters => ["CATEGORY", "TYPE_ID", "TAG_ID", "USER_ID",
                                "LICENSE_ID", "GROUP_ID", "WSDL_ENDPOINT",
                                "CURATION_EVENT", "SERVICE_PROVIDER",
                                "SERVICE_COUNTRY", "SERVICE_STATUS"])

        flash.now[:error] = problem if problem

        @query = params[:query]
        @query_type = 'workflows'

      end
      format.rss do
        #@workflows = Workflow.find(:all, :order => "updated_at DESC") # list all (if required)
        render :action => 'feed.rxml', :layout => false
      end
    end
  end
  
  # GET /workflows/1
  def show

    session = ROSRS::Session.new(@workflow.ro_uri, Conf.rodl_bearer_token)

    @annotations = session.get_annotation_graph(@workflow.ro_uri, workflow_url(@workflow))

    if allow_statistics_logging(@viewing_version)
      @viewing = Viewing.create(:contribution => @workflow.contribution, :user => (logged_in? ? current_user : nil), :user_agent => request.env['HTTP_USER_AGENT'], :accessed_from_site => accessed_from_website?())
    end

    @contributions_with_similar_services = @workflow.workflows_with_similar_services.select do |w|
      Authorization.check('view', w, current_user)
    end.map do |w|
      w.contribution
    end

    @wsdls_filter = { :filter => 'WSDL_ENDPOINT=(' + @workflow.unique_wsdls.map do |wsdl| '"' + wsdl.gsub(/"/, '\"') + '"' end.join(" OR ") + ')' }

    @similar_services_limit = 2

    respond_to do |format|
      format.html {

        if params[:version]
          @lod_nir  = workflow_version_url(:id => @workflow.id, :version => @viewing_version_number)
          @lod_html = workflow_version_url(:id => @workflow.id, :version => @viewing_version_number, :format => 'html')
          @lod_rdf  = workflow_version_url(:id => @workflow.id, :version => @viewing_version_number, :format => 'rdf')
          @lod_xml  = workflow_version_url(:id => @workflow.id, :version => @viewing_version_number, :format => 'xml')
        else
          @lod_nir  = workflow_url(@workflow)
          @lod_html = workflow_url(:id => @workflow.id, :format => 'html')
          @lod_rdf  = workflow_url(:id => @workflow.id, :format => 'rdf')
          @lod_xml  = workflow_url(:id => @workflow.id, :format => 'xml')
        end

        # show.rhtml
      }

      if Conf.rdfgen_enable
        format.rdf {
          if params[:version]
            render :inline => `#{Conf.rdfgen_tool} workflows #{@workflow.id} versions/#{@viewing_version.version}`
          else
            render :inline => `#{Conf.rdfgen_tool} workflows #{@workflow.id}`
          end
        }
      end
    end
  end

  # GET /workflows/new
  def new
  end

  # GET /workflows/1/new_version
  def new_version
  end

  # GET /workflows/1/edit
  def edit
  end
  
  # GET /workflows/1/edit_version
  def edit_version
  end

  # POST /workflows
  def create
    file = params[:workflow][:file]
    
    @workflow = Workflow.new
    @workflow.contributor = current_user
    @workflow.last_edited_by = current_user.id
    @workflow.license_id = params[:workflow][:license_id] == "0" ? nil : params[:workflow][:license_id]
    @workflow.content_blob = ContentBlob.new(:data => file.read)
    @workflow.file_ext = file.original_filename.split(".").last.downcase
    
    file.rewind
    
    # Check whether user has selected to infer metadata or provided custom metadata...
    
    # Infer metadata.
    if params[:metadata_choice] == 'infer'
      # Check that the file uploaded is recognised and can be parsed...
      
      worked = infer_metadata(@workflow, file)
      
      unless worked
        respond_to do |format|
          flash.now[:error] = "We were unable to infer metadata from the workflow file/script selected. Please enter custom metadata for this workflow."
          params[:metadata_choice] = 'custom'
          format.html { render :action => "new" }
        end
        return
      end
      
    # Custom metadata provided.
    elsif params[:metadata_choice] == 'custom'
      worked, error_message = set_custom_metadata(@workflow, file)
      
      unless worked
        respond_to do |format|
          flash.now[:error] = error_message
          format.html { render :action => "new" }
        end
        return
      end
    end
    
    respond_to do |format|
      if @workflow.save
        if params[:workflow][:tag_list]
          @workflow.refresh_tags(convert_tags_to_gem_format(params[:workflow][:tag_list]), current_user)
          @workflow.reload
          @workflow.solr_save if Conf.solr_enable
        end
        
        begin
          @workflow.extract_metadata
        rescue
        end

        policy_err_msg = update_policy(@workflow, params)

        # Credits and Attributions:
        update_credits(@workflow, params)
        update_attributions(@workflow, params)

        update_layout(@workflow, params[:layout])
        
        # Refresh the types handler list of types if a new type was supplied this time.
        WorkflowTypesHandler.refresh_all_known_types! if params[:workflow][:type] == 'other'

        if policy_err_msg.blank?
        	flash[:notice] = 'Workflow was successfully created.'
          format.html {
            if (@workflow.get_tag_suggestions.length > 0 || (@workflow.body.nil? || @workflow.body == ''))
              redirect_to tag_suggestions_workflow_url(@workflow)
            else
              redirect_to workflow_url(@workflow)
            end
          }
        else
        	flash[:notice] = "Workflow was successfully created. However some problems occurred, please see these below.</br></br><span style='color: red;'>" + policy_err_msg + "</span>"
          format.html { redirect_to :controller => 'workflows', :id => @workflow, :action => "edit" }
        end
      else
        format.html { render :action => "new" }
      end
    end
  end
  
  # POST /workflows/1/create_version
  def create_version
    wrong_type_err_msg = "The workflow you have provided is not of the same type as the original workflow. Please upload a valid #{@workflow.type_display_name} workflow (check that a valid file extension has been used and that the file doesn't contain any errors)."
    
    file = params[:workflow][:file]
    file_ext = file.original_filename.split(".").last.downcase
    
    # Because this is a new version of an existing workflow
    # we use the existing workflow object to set the data,
    # but then save it as a new version.
    
    @workflow.contributor_id = current_user.id
    @workflow.contributor_type = "User"
    @workflow.last_edited_by = current_user.id
    
    file.rewind
    
    # First and foremost check that the file uploaded is valid for the original workflow's content type.
    # This involves 2 different checks based on whether it is supported by a processor or not...
    
    wrong_type_err = false
    
    if @workflow.processor_class.nil?
      # Just need to check file extension matches
      wrong_type_err = true unless file_ext == @workflow.file_ext 
    else
      wrong_type_err = true unless workflow_file_matches_content_type_if_supported?(file, @workflow)
    end
    
    if wrong_type_err
      respond_to do |format|
        flash.now[:error] = wrong_type_err_msg
        format.html { render :action => :new_version }
      end
      return
    end
    
    
    # Check whether user has selected to infer metadata or provided custom metadata...
    
    # Infer metadata.
    if params[:metadata_choice] == 'infer'
      # Check that the file uploaded is recognised and can be parsed...
      
      worked = infer_metadata(@workflow, file)
      
      unless worked
        respond_to do |format|
          flash.now[:error] = "We were unable to infer metadata from the workflow file/script selected. Please enter custom metadata for this workflow."
          params[:metadata_choice] = 'custom'
          format.html { render :action => :new_version }
        end
        return
      end
      
    # Custom metadata provided.
    elsif params[:metadata_choice] == 'custom'
      worked, error_message = set_custom_metadata(@workflow, file)
      
      unless worked
        respond_to do |format|
          flash.now[:error] = wrong_type_err_msg
          format.html { render :action => :new_version }
        end
        return
      end
    end
    
    fail = false
    
    if @workflow.valid?
      # Save content blob first now and set it on the workflow.
      # TODO: wrap this in a transaction!
      @workflow.content_blob = ContentBlob.create(:data => file.read)
      @workflow.preview = nil
      @workflow[:revision_comments] = params[:new_workflow][:rev_comments]

      if @workflow.save

        # Extract workflow metadata using a Workflow object that includes the
        # newly created version.

        begin
          @workflow.reload
          @workflow.extract_metadata
        rescue
        end

        respond_to do |format|
          flash[:notice] = 'New workflow version successfully created.'
          format.html {

            @workflow.reload

            if (@workflow.get_tag_suggestions.length > 0 || (@workflow.body.nil? || @workflow.body == ''))
              redirect_to tag_suggestions_workflow_url(@workflow)
            else
              redirect_to workflow_url(@workflow)
            end
          }
        end
      else
        fail = true
      end
    else
      fail = true
    end
    
    if fail
      respond_to do |format|
        flash.now[:error] = 'Failed to upload and save new version. Check that you have provided the required data.'       
        format.html { render :action => :new_version }
      end
    end
   	
  end

  # PUT /workflows/1
  def update
    # remove protected columns
    if params[:workflow]
      [:contribution, :contributor_id, :contributor_type, :image, :svg, :created_at, :updated_at, :current_version, :content_type, :content_type_id, :file_ext, :content_blob_id].each do |column_name|
        params[:workflow].delete(column_name)
      end
    end
    
    # remove owner only columns
    unless @workflow.contribution.owner?(current_user)
      if params[:workflow]
        [:unique_name, :license_id].each do |column_name|
          params[:workflow].delete(column_name)
        end
      end
    end

    params[:workflow][:license_id] = nil if params[:workflow][:license_id] && params[:workflow][:license_id] == "0"

    respond_to do |format|
      # Here we assume that no actual workflow metadata is being updated that affects workflow versions,
      # so we need to prevent the timestamping update of workflow version objects.
      Workflow.record_timestamps = false
      
      if @workflow.update_attributes(params[:workflow])

        if params[:workflow][:tag_list]
          @workflow.refresh_tags(convert_tags_to_gem_format(params[:workflow][:tag_list]), current_user)
          @workflow.reload
          @workflow.solr_save if Conf.solr_enable
        end

        policy_err_msg = update_policy(@workflow, params)
        update_credits(@workflow, params)
        update_attributions(@workflow, params)

        update_layout(@workflow, params[:layout])

        if policy_err_msg.blank?
          flash[:notice] = 'Workflow was successfully updated.'
          format.html { redirect_to workflow_url(@workflow) }
        else
          flash[:notice] = "<span style='color: red;'>" + policy_err_msg + "</span>"
          format.html { redirect_to :controller => 'workflows', :id => @workflow, :action => "edit" }
        end
      else
        format.html { render :action => "edit" }
      end
      
      Workflow.record_timestamps = true
    end
  end
  
  # PUT /workflows/1;update_version
  def update_version

    success = false

    if params[:version]

      original_title = @workflow.title
      version        = @workflow.find_version(params[:version])
      do_preview     = !params[:workflow][:preview].blank? && params[:workflow][:preview].size > 0
      
      attributes_to_update = {
        :title          => params[:workflow][:title], 
        :body           => params[:workflow][:body],
        :last_edited_by => current_user.id
      }

      # only set the preview to update if one was provided

      attributes_to_update[:image] = params[:workflow][:preview] if do_preview

      success = version.update_attributes(attributes_to_update)
    end

    respond_to do |format|
      if success
        flash[:notice] = "Workflow version #{version.version}: \"#{original_title}\" has been updated."
        format.html { redirect_to(workflow_url(@workflow) + "?version=#{params[:version]}") }
      else
        flash[:error] = "Failed to update Workflow."
        if params[:version]
          format.html { render :action => :edit_version }
        else
          format.html { redirect_to workflow_url(@workflow) }
        end
      end
    end
  end
  
  # DELETE /workflows/1
  def destroy
    workflow_title = @workflow.title

    success = @workflow.destroy

    respond_to do |format|
      if success
        flash[:notice] = "Workflow \"#{workflow_title}\" has been deleted"
        format.html { redirect_to workflows_url }
      else
        flash[:error] = "Failed to delete Workflow entry \"#{workflow_title}\""
        format.html { redirect_to workflow_url(@workflow) }
      end
    end
  end
  
  # DELETE /workflows/1;destroy_version?version=1
  def destroy_version
    workflow_title = @viewing_version.title
    
    if params[:version]
      if @workflow.find_version(params[:version]) == false
        error("Version not found (is invalid)", "not found (is invalid)", :version)
      end
      if @workflow.versions.length < 2
        error("Can't delete all versions", " is not allowed", :version)
      end
      success = @workflow.destroy_version(params[:version].to_i)
    else
      success = false
    end
  
    respond_to do |format|
      if success
        flash[:notice] = "Workflow version #{params[:version]}: \"#{workflow_title}\" has been deleted"
        format.html { redirect_to workflow_url(@workflow) }
      else
        flash[:error] = "Failed to delete Workflow version. Please report this."
        if params[:version]
          format.html { redirect_to(workflow_url(@workflow) + "?version=#{params[:version]}") }
        else
          format.html { redirect_to workflow_url(@workflow) }
        end
      end
    end
  end
  
  def tag_suggestions
    @suggestions = @workflow.get_tag_suggestions
  end

  def process_tag_suggestions

    if params[:workflow] && params[:workflow][:body]
      @workflow.body = params[:workflow][:body]
      @workflow.save
    end

    params[:tag_list].split(',').each do |tag|
      @workflow.add_tag(tag.strip, current_user)
    end

    redirect_to(workflow_url(@workflow))
  end

  def auto_complete
    text = params[:workflow_name] || ''

    wfs = Workflow.find(:all,
                     :conditions => ["LOWER(title) LIKE ?", text.downcase + '%'],
                     :order => 'title ASC',
                     :limit => 20,
                     :select => 'DISTINCT *')

    wfs = wfs.select {|w| Authorization.check('view', w, current_user) }

    render :partial => 'contributions/autocomplete_list', :locals => { :contributions => wfs }
  end

  def edit_annotations

    session = ROSRS::Session.new(@workflow.ro_uri, Conf.rodl_bearer_token)

    @annotations = session.get_annotation_graphs(@workflow.ro_uri, workflow_url(@workflow))
  end

  def update_annotations
     
    session = ROSRS::Session.new(@workflow.ro_uri, Conf.rodl_bearer_token)

    resource_uri = workflow_url(@workflow)

    if params[:commit] == 'Add' || params[:commit] == 'Edit'

      case params[:template]
      when "Title"
        ao_body = @workflow.create_annotation_body(resource_uri,
            LibXML::XML::Node.new('dct:title', params[:value]),
            { "dct" => "http://purl.org/dc/terms/" })
      when "Creator"
        ao_body = @workflow.create_annotation_body(resource_uri,
            LibXML::XML::Node.new('dct:creator', params[:value]),
            { "dct" => "http://purl.org/dc/terms/" })
      when "Contributor"
        ao_body = @workflow.create_annotation_body(resource_uri,
            LibXML::XML::Node.new('dct:contributor', params[:value]),
            { "dct" => "http://purl.org/dc/terms/" })
      when "Description"
        ao_body = @workflow.create_annotation_body(resource_uri,
            LibXML::XML::Node.new('dct:description', params[:value]),
            { "dct" => "http://purl.org/dc/terms/" })
      end
    end

    if params[:commit] == 'Add'
      if ao_body
        agraph = ROSRS::RDFGraph.new(:data => ao_body.to_s, :format => :xml)

        code, reason, stub_uri, body_uri = session.create_internal_annotation(@workflow.ro_uri, resource_uri, agraph)
      end
    end

    if params[:commit] == 'Edit'
      if ao_body
        agraph = ROSRS::RDFGraph.new(:data => ao_body.to_s, :format => :xml)

        c, r, body_uri = session.update_internal_annotation(@workflow.ro_uri, params[:stub_uri], resource_uri, agraph)
      end
    end

    if params[:commit] == 'Delete'
      c, r, h, d = session.do_request("DELETE", params[:stub_uri], {} )
      c, r, h, d = session.do_request("DELETE", params[:body_uri], {} )
    end

    redirect_to edit_annotations_workflow_path(@workflow)
  end

protected

  def store_callback
    if params[:callback]
      session_object={ :url => params[:callback], :label => 'Launch', :additional => 'externally', :format => 'xml' }
      if params[:callback_contenttypes]
        session_object[:types] =
            params[:callback_contenttypes].split(',').map {|x| x.to_i }
      end
      if params[:callback_label]
        session_object[:label] = params[:callback_label]
      end 
      if params[:callback_additional]
        session_object[:additional] = params[:callback_additional]
      end 
      if params[:callback_format]
        session_object[:format] = params[:callback_format]
      end 
      session[:callback]=session_object
    end
  end

  def find_workflows_rss
    # Only carry out if request is for RSS
    if params[:format] and params[:format].downcase == 'rss'
      @rss_workflows = Authorization.scoped(Workflow, :authorised_user => current_user).find(:all, :limit => 30, :order => 'updated_at DESC')
    end
  end
  
  def find_workflow_auth

    action_permissions = {
      "create"                  => "create",
      "create_version"          => "edit",
      "destroy"                 => "destroy",
      "destroy_version"         => "edit",
      "download"                => "download",
      "edit"                    => "edit",
      "edit_annotations"        => "edit",
      "edit_version"            => "edit",
      "favourite"               => "view",
      "favourite_delete"        => "view",
      "galaxy_tool"             => "download",
      "galaxy_tool_download"    => "download",
      "index"                   => "view",
      "launch"                  => "download",
      "named_download"          => "download",
      "new"                     => "create",
      "new_version"             => "edit",
      "process_tag_suggestions" => "edit",
      "rate"                    => "view",
      "search"                  => "view",
      "show"                    => "view",
      "statistics"              => "view",
      "tag"                     => "view",
      "tag_suggestions"         => "view",
      "update"                  => "edit",
      "update_annotations"      => "edit",
      "update_version"          => "edit",
    }

    begin
      # Use eager loading only for 'show' action
      if action_name == 'show'
        workflow = Workflow.find(params[:id], :include => [ { :contribution => :policy }, :citations, :tags, :ratings, :versions, :reviews, :comments ])
      else
        workflow = Workflow.find(params[:id])
      end
      
      if Authorization.check(action_permissions[action_name], workflow, current_user)
        @latest_version_number = workflow.current_version

        @workflow = workflow
        if params[:version]
          if (viewing = @workflow.find_version(params[:version]))
            @viewing_version_number = params[:version].to_i
            @viewing_version = viewing
          else
            error("Workflow version not found (possibly has been deleted)", "not found (is invalid)", :version)
          end
        else
          @viewing_version_number = @latest_version_number
          @viewing_version = @workflow.find_version(@latest_version_number)
        end
        
        @authorised_to_edit = logged_in? && Authorization.check('edit', @workflow, current_user)
        if @authorised_to_edit
          # can save a call to .is_authorized? if "edit" was already found to be allowed - due to cascading permissions
          @authorised_to_download = true
        else
          @authorised_to_download = Authorization.check('download', @workflow, current_user)
        end
        
        # remove scufl from workflow if the user is not authorized for download
        @viewing_version.content_blob.data = nil unless @authorised_to_download
        @workflow.content_blob.data = nil unless @authorised_to_download
          
        @workflow_entry_url = url_for :only_path => false,
                                :host => base_host,
                                :id => @workflow.id
        
        @download_url = url_for :action => 'download',
                                :id => @workflow.id, 
                                :version => @viewing_version_number.to_s
        
        @named_download_url = url_for @workflow.named_download_url(@viewing_version_number) + "?version=#{@viewing_version_number.to_s}" 
                                      
        @launch_url = "/workflows/#{@workflow.id}/launch.whip?version=#{@viewing_version_number.to_s}"

        logger.debug("@latest_version_number = #{@latest_version_number}")
        logger.debug("@viewing_version_number = #{@viewing_version_number}")
        logger.debug("@workflow.image != nil = #{@workflow.image != nil}")
      else
        error("Workflow not found (id not authorized)", "is invalid (not authorized)", nil, 401)
        return false
      end
    rescue ActiveRecord::RecordNotFound
      error("Workflow not found", "is invalid")
      return false
    end
  end
  
  def initiliase_empty_objects_for_new_pages
    if ["new", "create"].include?(action_name)
      @workflow = Workflow.new
    end
    
    # HACK: required for the FCKEditor description and revision comments boxes, 
    # (the former is used in both new and new_version actions).
    @new_workflow = Workflow.new
    
    if ["new_version", "create_version"].include?(action_name)
      # Set the fields to the metadata from the previous version,
      # to aid user in setting the metadata.
      @new_workflow.body = @workflow.body
      params[:workflow] = { } unless params[:workflow]
      params[:workflow][:title] = @workflow.title
      # Determine which main metadata option to pre select based on whether metadata inference is supported for the workflow type.
      @workflow.can_infer_metadata_for_this_type? ? params[:metadata_choice] = "infer" : params[:metadata_choice] = "custom"
    end
    
    @new_workflow.body = params[:new_workflow][:body] if params[:new_workflow] && params[:new_workflow][:body]
    
    # Add a 'rev_comments' field to just this instance so that the FCKEditor box can pick it up.
    @new_workflow.extend Module.new { attr_accessor :rev_comments }
      
    if params[:new_workflow] && params[:new_workflow][:rev_comments]
      @new_workflow.rev_comments = params[:new_workflow][:rev_comments]
    end
  end
  
  def set_sharing_mode_variables
    case action_name
      when "new"
        @sharing_mode  = 0
        @updating_mode = 6
      when "create", "update"
        @sharing_mode  = params[:sharing][:class_id].to_i if params[:sharing]
        @updating_mode = params[:updating][:class_id].to_i if params[:updating]
      when "show", "edit"
        @sharing_mode  = @workflow.contribution.policy.share_mode
        @updating_mode = @workflow.contribution.policy.update_mode
    end
  end
  
  def check_file_size
    case action_name
      when "create"           then view_to_render_on_fail = "new"
      when "create_version"   then view_to_render_on_fail = "new_version"
    end
    
    # Check that a file has been selected 
    if params[:workflow][:file].size == 0
      respond_to do |format|
        flash.now[:error] = "Please select a valid workflow file to upload. If you have selected a file, it might be empty."
        format.html { render :action => view_to_render_on_fail }
      end
      return false
    # Check that the size of the workflow file doesn't exceed the max size
    elsif params[:workflow][:file].size > Conf.max_upload_size
      respond_to do |format|
        flash.now[:error] = "The workflow file/script uploaded is too big. The maximum upload size for workflows is #{number_to_human_size(Conf.max_upload_size)}."
        format.html { render :action => view_to_render_on_fail }
      end
      return false
    end
  end
  
  def check_custom_workflow_type
    case action_name
      when "create"           then view_to_render_on_fail = "new"
      when "create_version"   then view_to_render_on_fail = "new_version"
    end
    
    # Check that they selected a Workflow Type.

    if params[:metadata_choice] == 'custom' && params[:workflow][:type] == 'Select...'
      respond_to do |format|
        flash.now[:error] = "You selected custom metadata but did not specify a workflow type"
        format.html { render :action => view_to_render_on_fail }
      end
      return false
    end

    # If a custom workflow type has been specified, check that it is not "Other" or "other" as this can cause havoc in the UI.
    if params[:metadata_choice] == 'custom' && params[:workflow][:type] && params[:workflow][:type].downcase == 'other'

      custom_type_specified = params[:workflow][:type_other]

      if custom_type_specified.downcase == 'other'
        respond_to do |format|
          flash.now[:error] = "You cannot specify a new workflow type of \"#{custom_type_specified}\""
          format.html { render :action => view_to_render_on_fail }
        end
        return false
      end

      # check that they actually filled in the "Other" field.
      if custom_type_specified == ''
        respond_to do |format|
          flash.now[:error] = "You chose 'Other' as the Workflow Type but didn't enter a value for it"
          format.html { render :action => view_to_render_on_fail }
        end
        return false
      end
    end
  end
  
  def check_is_owner
    if @workflow
      error("You are not authorised to manage this Workflow", "") unless @workflow.owner?(current_user)
    end
  end
  
private


  #Upon specifying a group to share with, prompts the user whether or not they want to apply the groups'
  # custom skin

  def check_sharing_with_branded_group(new_groups)
    @groups_with_custom_layouts = nil
    new_shared_with_groups = nil

    # check if "shared with" groups has been changed in the update
    if action == "create" && params[:group_sharing]
      new_shared_with_groups = params[:group_sharing].keys
    elsif action == "update" && (@shared_with_groups_pre_update != @workflow.shared_with_networks)
      new_shared_with_groups = (@workflow.shared_with_networks - @shared_with_groups_pre_update).map { |n| n.ids }
    end

    if new_shared_with_groups && !params[:workflow][:skin]
      # check whether an added/removed group had styling options available
      group_ids = Conf.virtual_hosts.values.map {|v| v['group_id']} & new_shared_with_groups
      @groups_with_custom_layouts = Network.find(group_ids)
    end
  end

  def error(notice, message, attr=:id, status=nil)
    flash[:error] = notice
    (err = Workflow.new.errors).add(attr, message)
    
    respond_to do |format|
      format.html { redirect_to workflows_url }
      format.xml do
        headers["WWW-Authenticate"] = %(Basic realm="Web Password") if status == 401
        render :text => notice, :status => status
      end
    end
  end
  
  def construct_options
    valid_keys = ["contributor_id", "contributor_type"]
    
    cond_sql = ""
    cond_params = []
    
    params.each do |key, value|
      next if value.nil?
      
      if valid_keys.include? key
        cond_sql << " AND " unless cond_sql.empty?
        cond_sql << "#{key} = ?" 
        cond_params << value
      end
    end
    
    options = {:order => "updated_at DESC"}
    
    # added to faciliate faster requests for iGoogle gadgets
    # ?limit=0 returns all workflows (i.e. no limit!)
    options = options.merge({:limit => params[:limit]}) if params[:limit] and (params[:limit].to_i != 0)
    
    options = options.merge({:conditions => [cond_sql] + cond_params}) unless cond_sql.empty?
    
    options
  end
  
  # Method used in the create and create_version methods.
  def infer_metadata(workflow_to_set, file)
    # Rewind the file, just in case
    file.rewind
    
    # Try and get a processor that can be used to process this type of workflow
    processor_class = WorkflowTypesHandler.processor_class_for_file(file)
    
    # Rewind the file, just in case
    file.rewind
    
    # Status check variable
    worked = true
    
    if processor_class.nil?
      worked = false
      logger.debug("A workflow processor for the file uploaded could not be found!")
    else
      # Check that the processor can do inferring of metadata
      if processor_class.can_infer_metadata?
        begin
          processor_instance = processor_class.new(file.read)
          
          # Rewind the file, just in case
          file.rewind
          
          workflow_to_set.title = processor_instance.get_title      if processor_instance.get_title
          workflow_to_set.body = processor_instance.get_description if processor_instance.get_description
          
          workflow_to_set.content_type = ContentType.find_by_title(processor_class.display_name)
          
          # Set the internal unique name for this particular workflow (or workflow_version).
          workflow_to_set.set_unique_name
          
          workflow_to_set.image = processor_instance.get_preview_image.read if processor_class.can_generate_preview_image?
          workflow_to_set.svg   = processor_instance.get_preview_svg.read   if processor_class.can_generate_preview_svg?
        rescue Exception => ex
          worked = false
          err_msg = "ERROR: some processing failed in workflow processor '#{processor_class.to_s}'.\nEXCEPTION: #{ex}"
          logger.error err_msg
        end
      else
        # We cannot infer metadata
        worked = false
        logger.debug("Workflow processor found but it cannot infer metadata!")
      end
    end
    
    return worked
  end
  
  # Method used in the create and create_version methods.
  def set_custom_metadata(workflow_to_set, file)
    
    workflow_to_set.title = params[:workflow][:title]
    workflow_to_set.body = params[:new_workflow][:body]
    
    # Only set content_type if not already set in the workflow object
    if workflow_to_set.content_type.blank?
      # Workflow content type is either one supported by a workflow processor, or a previously set type in the db, or a custom one.
    
      wf_type = params[:workflow][:type]
    
      if wf_type.downcase == 'other'

        # Reuse an existing ContentType record if it exists already but the UI didn't have it.
     
        ct = ContentType.find_by_title(params[:workflow][:type_other])

        if ct.nil?
          ct = ContentType.create(:user_id => current_user.id,
            :mime_type => file.content_type, :title => params[:workflow][:type_other],
            :category => 'Workflow')
        end

        if !ct.valid?

          other_ct = ContentType.find_by_mime_type(file.content_type)

          if other_ct
            return [false, "Unable to create new type because the MIME type \"#{file.content_type}\" is already used by the \"#{other_ct.title}\" type."]
          end

          return [false, "Unable to create new type."]
        end

        workflow_to_set.content_type = ct
      else
        workflow_to_set.content_type = ContentType.find_by_title(wf_type)
      end
    end
    
    # Check that the file uploaded is valid for the content type chosen (if supported by a workflow processor).
    # This is to ensure that the correct content type is being assigned to the workflow file uploaded.
    if !workflow_file_matches_content_type_if_supported?(file, workflow_to_set)
      return [false, "The file provided isn't a workflow of the type specified. Please select a different file or set an appropriate content type."]
    end
    
    # Preview image
    # TODO: kept getting permission denied errors from the file_column and rmagick code, so disable for windows, for now.
    #
    # The dependency on file_column has been removed, but this code remains
    # disabled on Windows until it is confirmed as working.
    unless RUBY_PLATFORM =~ /mswin32/
      preview = params[:workflow][:preview]
      if preview
        preview_size = -1
        if preview.kind_of?(File)
          preview_size = preview.stat.size
        elsif preview.kind_of?(StringIO) || preview.kind_of?(Tempfile)
            preview_size = preview.size
        end
        workflow_to_set.image = preview.read if preview_size>0
      end
    end
    
    # Set the internal unique name for this particular workflow (or workflow_version).
    workflow_to_set.set_unique_name
    
    return [true, nil]
  end
  
  # This method checks to to see if the file specified is a valid one for the existing workflow specified,
  # but only if the existing workflow specified has a supporting processor.
  # If no supporting processor is found then validity cannot be determined so we assume the file is valid for the content type.
  #
  # Note: this will check whether the file extension is supported and, if the processor allows for it, 
  # checks if the file is "recognised" by the processor as a valid workflow of that type.
  def workflow_file_matches_content_type_if_supported?(file, existing_workflow)
    ok = true
    
    proc_class = existing_workflow.processor_class
      
    if proc_class
      # Check that the file extension of the file specified is supported by the processor.
      file_ext = file.original_filename.split(".").last.downcase
      ok = false unless proc_class.file_extensions_supported.include?(file_ext)
      
      # Now check that the file can be "recognised", if the processor allows for this.
      # We do this by checking that the processor class, obtained from the types handler, for the specified file matches 
      # the processor class obtained before, for the content type specified.
      if proc_class.can_determine_type_from_file?
        if proc_class != WorkflowTypesHandler.processor_class_for_file(file)
          ok = false
        end
      end
    end
    return ok
  end

end

