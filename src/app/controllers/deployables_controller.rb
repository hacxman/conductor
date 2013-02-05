#
#   Copyright 2011 Red Hat, Inc.
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.
#
require 'uri'

class DeployablesController < ApplicationController
  before_filter :require_user
  include DeployablesP::ShowP

  def index
    clear_breadcrumbs
    if params[:catalog_id].present?
      save_breadcrumb(catalog_deployables_path(:viewstate => @viewstate ? @viewstate.id : nil))
      @catalog = Catalog.find(params[:catalog_id])
      @deployables = @catalog.deployables
      @catalog_entries = @deployables.collect { |d| d.catalog_entries.first }
    elsif params[:pool_id].present?
      # possible enumeration attack? as well as ^^
      # * should list only those user can VIEW
      # * do we allow traversing unpriviledged resources?
      #   i.e. when user doesn't have VIEW perm for Catalog or Pool

      Deployable.transaction do
        Pool.find(params[:pool_id])
        # only for it's side effect of raising exception in case of 404
        catalogs = Catalog.find_all_by_pool_id(params[:pool_id])
        deployables = catalogs.map { |_c| _c.deployables }.reduce([], &:+)

        perm_deployables = Deployable.
          list_for_user(current_session, current_user, Privilege::VIEW)

        @deployables = deployables.to_set & perm_deployables.to_set
      end
    else
      respond_to do |format|
        format.html {
          save_breadcrumb(deployables_path)
          @deployables = Deployable.without_catalog.
            list_for_user(current_session, current_user, Privilege::VIEW)
        }
        format.xml {
          @deployables = Deployable.
            list_for_user(current_session, current_user, Privilege::VIEW)
        }
      end
    end
    set_header
    respond_to do |format|
      format.html
      format.xml { render :partial => 'list.xml', :locals => {:deployables => @deployables}}
    end
  end

  def new
    @deployable = Deployable.new(params[:deployable])
    if params[:create_from_image]
      @image = Aeolus::Image::Warehouse::Image.find(params[:create_from_image])
      @hw_profiles = HardwareProfile.frontend.
        list_for_user(current_session, current_user, Privilege::VIEW)
      @deployable.name = @image.name
      @selected_catalogs = Array(params[:catalog_id])
      load_catalogs
      @selected_catalogs.each do |catalog_id|
        require_privilege(Privilege::CREATE, Deployable, Catalog.find_by_id(catalog_id))
      end
      flasherr = []
      flasherr << t("deployables.flash.error.no_catalog_exists") if @catalogs.empty?
      flasherr << t("deployables.flash.error.no_hwp_exists") if @hw_profiles.empty?
      @save_disabled = !(flasherr.empty?)
      flash[:error] = flasherr if not flasherr.empty?
    elsif params[:catalog_id].present?
      @catalog = Catalog.find(params[:catalog_id])
      require_privilege(Privilege::CREATE, @catalog, Deployable)
    end
    @form_option= params.has_key?(:from_url) ? 'from_url' : 'upload'
    respond_to do |format|
        format.html
        format.js {render :partial => @form_option}
    end
  end

  def show
    respond_to do |format|
      format.html do
        result = DeployablesP::ShowP::wui(params)
        
        @deployable = result.deployable
        @catalog = result.catalog
        @providers = result.providers
        @catalogs_options = result.catalogs_options
        @images_details = result.images_details
        @missing_images = result.missing_images
        @deployable_errors = result.deployable_errors
        @image_status = result.image_status
        @pushed_count = result.pushed_count
        
        render :partial => 'show', :locals => result
      end
      format.json do
        render :json => { :image_status => @image_status }
      end
      format.xml do
        render :partial => 'show', :locals =>
          {:deployable => @deployable, :catalog => @catalog,
           :images => images}
      end
    end

  end

  def definition
    @deployable = Deployable.find(params[:id])
    require_privilege(Privilege::VIEW, @deployable)
    render :xml => @deployable.xml
  end

  def create
    if params[:cancel]
      redirect_to polymorphic_path([params[:catalog_id], Deployable])
      return
    end

    @deployable = Deployable.new(params[:deployable])
    @selected_catalogs = Catalog.find(Array(params[:catalog_id]))
    @deployable.owner = current_user
    @selected_catalogs.each do |catalog|
      require_privilege(Privilege::CREATE, Deployable, catalog)
    end

    if params.has_key? :url
      xml, error = import_xml_from_url(params[:url])
      unless xml.nil?
        #store xml_filename for url (i.e. url ends to: foo || foo.xml)
        @deployable.xml_filename =  File.basename(URI.parse(params[:url]).path)
        @deployable.xml = xml
      end
    elsif params[:create_from_image].present?
      hw_profile = HardwareProfile.frontend.find(params[:hardware_profile])
      require_privilege(Privilege::VIEW, hw_profile)
      @deployable.set_from_image(params[:create_from_image], params[:deployable][:name], hw_profile)
    end

    begin
      raise t("deployables.flash.error.no_catalog") if @selected_catalogs.empty?
      @deployable.transaction do
        @selected_catalogs.each do |catalog|
          @deployable.catalogs << catalog
        end
        @deployable.save!
        flash[:notice] = t("catalog_entries.flash.notice.added", :catalog => @selected_catalogs.map{|c| c.name}.join(", "))
        if params[:edit_xml]
          redirect_to edit_polymorphic_path([@selected_catalogs.first, @deployable], :edit_xml =>true)
        elsif params[:create_from_image]
          redirect_to @deployable
        else
          redirect_to catalog_path(@selected_catalogs.first)
        end
      end

      # check that type attrs on service params are used properly
      warnings = @deployable.check_service_params_types
      unless warnings.empty?
        flash[:warning] ||= []
        flash[:warning] = [flash[:warning]] if flash[:warning].kind_of? String
        flash[:warning]+=warnings
      end

    rescue => e
      @deployable.errors.add(:url, error) if error
      if @deployable.errors.empty?
        logger.error e.message
        logger.error e.backtrace.join("\n ")
        flash.now[:warning]= t('deployables.flash.warning.failed', :message => e.message)
      end
      if params[:create_from_image].present?
        @image = Aeolus::Image::Warehouse::Image.find(params[:create_from_image])
        load_catalogs
        @hw_profiles = HardwareProfile.frontend.
          list_for_user(current_session, current_user, Privilege::VIEW)
      else
        @catalog = @selected_catalogs.first
        params.delete(:edit_xml) if params[:edit_xml]
        @form_option = params[:form_option].eql?('upload') ? 'upload' : 'from_url'
      end
      render :new
    end
  end

  def edit
    @deployable = Deployable.find(params[:id])
    require_privilege(Privilege::MODIFY, @deployable)
    @catalog = Catalog.find(params[:catalog_id]) if params[:catalog_id].present?
  end

  def update
    @deployable = Deployable.find(params[:id])
    @catalog = Catalog.find(params[:catalog_id]) if params[:catalog_id].present?
    require_privilege(Privilege::MODIFY, @deployable)
    params[:deployable].delete(:owner_id) if params[:deployable]

    if @deployable.update_attributes(params[:deployable])
      # check that type attrs on service params are used properly
      warnings = @deployable.check_service_params_types
      unless warnings.empty?
        flash[:warning] ||= []
        flash[:warning] = [flash[:warning]] if flash[:warning].kind_of? String
        flash[:warning]+=warnings
      end

      flash[:notice] = t"catalog_entries.flash.notice.updated"
      redirect_to polymorphic_path([@catalog, @deployable])
    else
      render :action => 'edit', :edit_xml => params[:edit_xml]
    end
  end

  # the name here is confusing; we may want to rename to multi_remove at some point
  def multi_destroy
    deleted = []
    not_deleted = []
    not_deleted_perms = []

    @catalog = Catalog.find(params[:catalog_id])

    if params[:deployables_selected]
      Deployable.find(params[:deployables_selected]).to_a.each do |d|
        if check_privilege(Privilege::MODIFY, d)
          if d.catalog_entries.where(:catalog_id => @catalog.id).first.destroy
            deleted << d.name
          else
            not_deleted << d.name
          end
        else
          not_deleted_perms << d.name
        end
      end
      unless not_deleted.empty? and not_deleted_perms.empty?
        flasherr = []
        flasherr =  t("deployables.flash.error.not_deleted", :count => not_deleted.count, :not_deleted => not_deleted.join(', ')) unless not_deleted.empty?
        flasherr =  t("deployables.flash.error.not_deleted_perms", :count => not_deleted_perms.count, :not_deleted => not_deleted_perms.join(', ')) unless not_deleted_perms.empty?
        flash[:error] = flasherr
      end
      flash[:notice] = t("deployables.flash.notice.deleted", :count => deleted.count, :deleted => deleted.join(', ')) unless deleted.empty?
    else
      flash[:error] = t("deployables.flash.error.not_selected")
    end

    if @catalog.present?
      redirect_to catalog_path(@catalog)
    else
      redirect_to deployables_path
    end
  end

  def destroy
    deployable = Deployable.find(params[:id])
    @catalog = Catalog.find(params[:catalog_id]) if params[:catalog_id].present?
    require_privilege(Privilege::MODIFY, deployable)
    if deployable.destroy
      flash[:notice] = t("deployables.flash.notice.deleted.one", :deleted => deployable.name)
    else
      flash[:error] = t("deployables.flash.error.not_deleted.one", :not_deleted => deployable.name)
    end

    respond_to do |format|
      format.html do
        if @catalog.present?
          redirect_to catalog_path(@catalog)
        else
          redirect_to deployables_path
        end
      end

      format.xml do
        if deployable.destroyed?
          render :text => '', :status => :no_content
        else
          raise Aeolus::Conductor::API::Error.new(500,
            deployable.errors.full_messages.join(', '))
        end
      end
    end
  end

  def filter
    redirect_to_original({"deployables_preset_filter" => params[:deployables_preset_filter], "deployables_search" => params[:deployables_search]})
  end

  private

  def set_header
    @header = [
      { :name => 'checkbox', :class => 'checkbox', :sortable => false },
      { :name => t("catalog_entries.index.name"), :sort_attr => :name },
      { :name => t("catalogs.index.catalog_name"), :sortable => false },
      { :name => t("catalog_entries.index.deployable_xml"), :sortable => :url }
    ]
  end

  def load_catalogs
    @pool_family = PoolFamily.where(:name => @image.environment).first
    @catalogs = Catalog.list_for_user(current_session, current_user,
                                      Privilege::CREATE, Deployable).
      where('pool_family_id' => @pool_family.id)
  end
end
