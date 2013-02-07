module RestrictedPresenter
  class << self
    def included(base)
      p base
      p 'kokot'
      base.class_eval do
        def self.included(base)
          p base
          p 'jebem ti rit'
          # wrap it!
          to_wrap = instance_methods - ancestors[1].instance_methods
          to_wrap.each do |fname|
            alias_method "__#{fname.to_s}".to_sym, fname
            define_method fname do |*lampa, &block|
              blank_slate = Class.new do
                instance_methods.each do |m|
                  undef_method m unless m.to_s =~ /method_missing|respond_to?|^__|^instance_variable|^define_method/
                end
              end

              vars_to_copy = [:@session]

              slate = blank_slate.new
              vars_to_copy.each do |var|
                slate.instance_variable_set(var, instance_variable_get(var))
              end

              controller_self = self

              mets_to_copy = [:require_privilege]
              mets_to_copy.each do |m|
                slate.define_method m do |*p, &b|
                  controller_self.send m, p, b
                end
              end

              slate.instance_eval do
                controller_self.send "__#{fname}".to_sym, lampa, block
              end

            end
          end
        end
      end
    end
  end
end

module DeployablesP
  module ShowP
    include RestrictedPresenter

    Res = Struct.new(:deployable, :catalog, :providers, :catalogs_options,
                     :images_details, :missing_images, :deployable_errors,
                     :image_status, :pushed_count)
    def wui(params)

      deployable = Deployable.find(params[:id])
      catalog = params[:catalog_id].present? ? Catalog.find(params[:catalog_id]) : deployable.catalogs.first
      require_privilege(Privilege::VIEW, deployable)
      save_breadcrumb(polymorphic_path([catalog, deployable]), deployable.name)
      providers = Provider.all
      catalogs_options = Catalog.list_for_user(current_session, current_user,
                                                Privilege::MODIFY).select do |c|
        !deployable.catalogs.include?(c) and
          deployable.catalogs.first.pool_family == c.pool_family
      end

      if catalog.present?
        add_permissions_inline(deployable, '', {:catalog_id => catalog.id})
      else
        add_permissions_inline(deployable)
      end

      images_details, images, missing_images, deployable_errors = deployable.get_image_details
      flash.now[:error] = deployable_errors unless deployable_errors.empty?

      if missing_images.empty?
        image_status = []
        pushed_count = 0

        deployable.pool_family.provider_accounts.includes(:provider).
                    where('providers.enabled' => true).each do |provider_account|
          deltacloud_driver =
            provider_account.provider.provider_type.deltacloud_driver
          build_status = deployable.build_status(images, provider_account)
          pushed_count += 1 if (build_status == :pushed)

          image_status << {
            :deltacloud_driver => deltacloud_driver,
            :provider_account_label => provider_account.label,
            :provider_name => provider_account.provider.name,
            :build_status => build_status,
            :translated_build_status =>
              t("deployables.show.build_statuses_descriptions.#{build_status}")
          }

          image_status.sort_by do |image_status_for_account|
            image_status_for_account[:deltacloud_driver]
          end
        end
      end

      result = Res.new
      result.deployable = deployable
      result.catalog = catalog
      result.providers = providers
      result.catalogs_options = catalogs_options
      result.images_details = images_details
      result.missing_images = missing_images
      result.deployable_errors = deployable_errors
      result.image_status = image_status
      result.pushed_count = pushed_count

      result
    end

    def api(params)
    end
  end
end
