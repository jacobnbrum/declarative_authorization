# Authorization::AuthorizationInController
require File.dirname(__FILE__) + '/authorization.rb'

module Authorization
  module AuthorizationInController
  
    def self.included(base) # :nodoc:
      base.extend(ClassMethods)
    end
    
    # Returns the Authorization::Engine for the current controller.
    def authorization_engine
      @authorization_engine ||= Authorization::Engine.new
    end
    
    # If the current user meets the given privilege, permitted_to? returns true
    # and yields to the optional block.  The attribute checks that are defined
    # in the authorization rules are only evaluated if an object is given
    # for context.
    # 
    # See examples for Authorization::AuthorizationHelper #permitted_to?
    #
    def permitted_to? (privilege, object_or_sym = nil, &block)
      context = object = nil
      if object_or_sym.is_a?(Symbol)
        context = object_or_sym
      else
        object = object_or_sym
      end
      # TODO infer context also from self.class.name
      authorization_engine.permit?(privilege, 
          {:user => current_user, 
           :object => object,
           :context => context,
           :skip_attribute_test => object.nil?}, 
          &block)
    end
    
    module ClassMethods
      #
      # Defines a filter to be applied according to the authorization of the
      # current user.  Requires at least one symbol corresponding to an
      # action as parameter.  The special symbol :+all+ refers to all action.
      #   class UserController < ActionController
      #     filter_access_to :index
      #     filter_access_to :new, :edit
      #     filter_access_to :all
      #     ...
      #   end
      # 
      # By default, required privileges are infered from the action name and
      # the controller name.  Thus, in UserController :+edit+ requires
      # :+edit_users+.  To specify required privilege, use the option :+require+
      #   filter_access_to :new, :create, :require => :create_users
      #   
      # For further customization, a custom filter expression may be formulated
      # in a block, which is then evaluated in the context of the controller
      # on a matching request.  That is, for checking two objects, use the 
      # following:
      #   filter_access_to :merge do
      #     authorization_engine.permit!(:update, :context => :users,
      #                                  :object => User.find(params[:original_id]),
      #                                  :user => current_user) and
      #       authorization_engine.permit!(:delete, :context => :users,
      #                                    :object => User.find(params[:id]),
      #                                    :user => current_user)
      #   end
      # The block should raise a Authorization::AuthorizationError or return
      # false if the access is to be denied.
      # 
      # Later calls to filter_access_to with overlapping actions overwrite
      # previous ones for that action.
      # 
      # All options:
      # [:+require+] 
      #   Privilege required; defaults to action_name
      # [:+context+] 
      #   The privilege's context, defaults to controller_name, pluralized.
      # [:+attribute_check+]
      #   Enables the check of attributes defined in the authorization rules.
      #   Defaults to false.  If enabled, filter_access_to will try to load
      #   a context object employing either 
      #   * the method from the :+load_method+ option or 
      #   * a find on the context model, using +params+[:id] as id value.
      #   Any of these loading methods will only be employed if :+attribute_check+
      #   is enabled.
      # [:+model+] 
      #   The data model to load a context object from.  Defaults to the
      #   context, singularized.
      # [:+load_method+]
      #   Specify a method by symbol or a Proc object which should be used 
      #   to load the object.  Both should return the loaded object.
      #   If a Proc object is given, e.g. by way of
      #   +lambda+, it is called in the instance of the controller.  
      #   Example demonstrating the default behaviour:
      #     filter_access_to :show, :attribute_check => true,
      #                      :load_method => lambda { User.find(params[:id]) }
      # 
      
      def filter_access_to (*args, &filter_block)
        options = args.last.is_a?(Hash) ? args.pop : {}
        options = {
          :require => nil,
          :context => nil,
          :attribute_check => false,
          :model => nil,
          :load_method => nil
        }.merge!(options)
        privilege = options[:require]
        context = options[:context]
        actions = args

        # TODO currently: default deny; make this configurable
        # collect permits in controller array for use in one before_filter
        unless class_variable_defined?(:@@permissions)
          permissions = []
          class_variable_set(:@@permissions, permissions)
          before_filter do |contr|
            all_permissions = permissions.select {|p| p.actions.include?(:all)}
            matching_permissions = permissions.select {|p| p.matches?(contr.action_name)}
            allowed = false
            auth_exception = nil
            begin
              allowed = if !matching_permissions.empty?
                          matching_permissions.all? {|perm| perm.permit!(contr)}
                        elsif !all_permissions.empty?
                          all_permissions.all? {|perm| perm.permit!(contr)}
                        else
                          false
                        end
            rescue AuthorizationError => e
              auth_exception = e
            end
            
            unless allowed
              if all_permissions.empty? and matching_permissions.empty?
                contr.logger.warn "Permission denied: No matching filter access " +
                  "rule found for #{contr.class.controller_name}.#{contr.action_name}"
              elsif auth_exception
                contr.logger.info "Permission denied: #{auth_exception}"
              end
              if contr.respond_to?(:permission_denied)
                # permission_denied needs to render or redirect
                contr.send(:permission_denied)
              else
                contr.send(:render, :text => "You are not allowed to access this action.")
              end
            end
          end
        end
        
        class_variable_get(:@@permissions).each do |perm|
          perm.remove_actions(actions)
        end
        class_variable_get(:@@permissions) << 
          ControllerPermission.new(actions, privilege, context,
                                   options[:attribute_check],
                                   options[:model],
                                   options[:load_method],
                                   filter_block)
      end
    end 
  end
  
  class ControllerPermission # :nodoc:
    attr_reader :actions, :privilege, :context
    def initialize (actions, privilege, context, attribute_check = false, 
                    load_object_model = nil, load_object_method = nil,
                    filter_block = nil)
      @actions = actions.to_set
      @privilege = privilege
      @context = context
      @load_object_model = load_object_model
      @load_object_method = load_object_method
      @filter_block = filter_block
      @attribute_check = attribute_check
    end
    
    def matches? (action_name)
      @actions.include?(action_name.to_sym)
    end
    
    def permit! (contr)
      if @filter_block
        return contr.instance_eval(&@filter_block)
      end
      context = @context || contr.class.controller_name.pluralize.to_sym
      object = @attribute_check ? load_object(contr, context) : nil
      privilege = @privilege || :"#{contr.action_name}"
      
      #puts "Trying permit?(#{privilege.inspect}, "
      #puts "               :user => #{contr.send(:current_user).inspect}, "
      #puts "               :object => #{object.inspect}," 
      #puts "               :skip_attribute_test => #{!@attribute_check}," 
      #puts "               :context => #{contr.class.controller_name.pluralize.to_sym})"
      res = contr.authorization_engine.permit!(privilege, 
                                         :user => contr.send(:current_user),
                                         :object => object,
                                         :skip_attribute_test => !@attribute_check,
                                         :context => context)
      #puts "permit? result: #{res.inspect}"
      res
    end
    
    def remove_actions (actions)
      @actions -= actions
    end
    
    private
    def load_object(contr, context)
      if @load_object_method and @load_object_method.is_a?(Symbol)
        contr.send(@load_object_method)
      elsif @load_object_method and @load_object_method.is_a?(Proc)
        contr.instance_eval(&@load_object_method)
      else
        load_object_model = @load_object_model || context.to_s.classify.constantize
        instance_var = :"@#{load_object_model.name.underscore}"
        object = contr.instance_variable_get(instance_var)
        unless object
          # catch ActiveRecord::RecordNotFound?
          object = load_object_model.find(contr.params[:id])
          contr.instance_variable_set(instance_var, object)
        end
        object
      end
    end
  end
end