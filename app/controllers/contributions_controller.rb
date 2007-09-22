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

class ContributionsController < ApplicationController
  before_filter :login_required, :except => [:index, :show]
  
  before_filter :find_contributions, :only => [:index]
  before_filter :find_contribution, :only => [:show]
  before_filter :find_contribution_auth, :only => [:edit, :update, :destroy]
  
  # GET /contributions
  # GET /contributions.xml
  def index
    respond_to do |format|
      format.html # index.rhtml
      format.xml  { render :xml => @contributions.to_xml }
    end
  end

  # GET /contributions/1
  # GET /contributions/1.xml
  def show
    respond_to do |format|
      format.html # show.rhtml
      format.xml  { render :xml => @contribution.to_xml }
    end
  end

  # GET /contributions/new
  def new
    @contribution = Contribution.new
  end

  # GET /contributions/1;edit
  def edit

  end

  # POST /contributions
  # POST /contributions.xml
  def create
    @contribution = Contribution.new(params[:contribution])

    respond_to do |format|
      if @contribution.save
        flash[:notice] = 'Contribution was successfully created.'
        format.html { redirect_to contribution_url(@contribution) }
        format.xml  { head :created, :location => contribution_url(@contribution) }
      else
        format.html { render :action => "new" }
        format.xml  { render :xml => @contribution.errors.to_xml }
      end
    end
  end

  # PUT /contributions/1
  # PUT /contributions/1.xml
  def update
    # security bugfix: do not allow owner to change protected columns
    [:contributor_id, :contributor_type, :contributable_id, :contributable_type].each do |column_name|
      params[:contribution].delete(column_name)
    end
    
    respond_to do |format|
      if @contribution.update_attributes(params[:contribution])
        flash[:notice] = 'Contribution was successfully updated.'
        format.html { redirect_to contribution_url(@contribution) }
        format.xml  { head :ok }
      else
        format.html { render :action => "edit" }
        format.xml  { render :xml => @contribution.errors.to_xml }
      end
    end
  end

  # DELETE /contributions/1
  # DELETE /contributions/1.xml
  def destroy
    @contribution.destroy

    respond_to do |format|
      format.html { redirect_to contributions_url }
      format.xml  { head :ok }
    end
  end
  
protected

  def find_contributions()
    valid_keys = ["contributor_id", "contributor_type", "contributable_type"]
    
    cond_sql = ""
    cond_params = []
    
    params.each do |key, value|
      if valid_keys.include? key
        cond_sql << " AND " unless cond_sql.empty?
        cond_sql << "#{key} = ?" 
        cond_params << value
      end
    end
    
    options = { :order => "contributable_type ASC, created_at DESC",
                :page => { :size => 20, 
                           :current => params[:page] } }
    options = options.merge( { :conditions => [cond_sql] + cond_params }) unless cond_sql.empty?
    
    @contributions = Contribution.find(:all, options)
  end
  
  def find_contribution
    begin
      contribution = Contribution.find(params[:id])
      
      if contribution.authorized?(action_name, (logged_in? ? current_user : nil))
        @contribution = contribution
      else
        error("Contribution not found (id not authorized)", "is invalid (not authorized)")
      end
    rescue ActiveRecord::RecordNotFound
      error("Contribution not found", "is invalid")
    end
  end
  
  def find_contribution_auth
    begin
      contribution = Contribution.find(params[:id])
      
      if contribution.owner?(current_user)
        @contribution = contribution
      else
        error("Contribution not found (id not owner)", "is invalid (not owner)")
      end
    rescue ActiveRecord::RecordNotFound
      error("Contribution not found", "is invalid")
    end
  end

private

  def error(notice, message, attr=:id)
    flash[:notice] = notice
    (err = Contribution.new.errors).add(attr, message)
    
    respond_to do |format|
      format.html { redirect_to contributions_url }
      format.xml { render :xml => err.to_xml }
    end
  end
end
