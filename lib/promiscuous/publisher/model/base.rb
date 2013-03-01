module Promiscuous::Publisher::Model::Base
  extend ActiveSupport::Concern

  included do
    class_attribute :publish_to, :published_attrs, :tracked_attrs
    cattr_accessor  :published_db_fields # There is one on each root class, none on the subclasses
    self.published_attrs = []
    self.tracked_attrs = []
    self.published_db_fields = []
    track_dependencies_of :id
    Promiscuous::Publisher::Model.publishers << self
  end

  module PromiscuousMethodsBase
    def initialize(instance)
      @instance = instance
    end

    def sync(options={}, &block)
      options = {:instance => @instance, :operation => :update}.merge(options)
      Promiscuous::Publisher::Operation::Base.new(options).commit(&block)
    end

    def payload(options={})
      # It's nice to see the entire payload in one piece, not merged 36 times
      msg = {}
      msg[:__amqp__]      = @instance.class.publish_to
      msg[:type]          = @instance.class.publish_as # for backward compatibility
      msg[:ancestors]     = @instance.class.ancestors.select { |a| a < Promiscuous::Publisher::Model::Base }.map(&:publish_as)
      msg[:id]            = @instance.id.to_s
      msg[:payload]       = self.attributes        if options[:operation].in?([nil, :create, :update])
      msg[:operation]     = options[:operation]    if options[:operation]
      msg[:dependencies]  = options[:dependencies] if options[:dependencies]
      msg[:transaction]   = options[:transaction]  if options[:transaction]
      msg[:timestamp]     = options[:timestamp]    if options[:timestamp]
      msg
    end

    def attributes
      Hash[@instance.class.published_attrs.map { |attr| [attr, self.attribute(attr)] }]
    end

    def attribute(attr)
      value = @instance.__send__(attr)
      value = value.promiscuous.payload if value.respond_to?(:promiscuous)
      value
    end

    def publish(options={})
      payload = self.payload(options)
      Promiscuous::AMQP.publish(:key => payload[:__amqp__], :payload => payload.to_json)
    rescue Exception => e
      raise Promiscuous::Error::Publisher.new(e, :instance => @instance, :payload => payload, :out_of_sync => true)
    end

    def get_dependency(attr, value)
      return nil unless value
      @collection ||= @instance.class.promiscuous_collection_name
      Promiscuous::Dependency.new(@collection, attr, value)
    end

    def tracked_dependencies(options={})
      # FIXME This is not sufficient, we need to consider the previous and next
      # values in case of an update.
      @instance.class.tracked_attrs
        .map { |attr| [attr, @instance.__send__(attr)]}
        .map { |attr, value| get_dependency(attr, value) }
        .compact
    end
  end

  class PromiscuousMethods
    include Promiscuous::Publisher::Model::Base::PromiscuousMethodsBase
  end

  def promiscuous
    # XXX Not thread safe
    @promiscuous ||= self.class.const_get(:PromiscuousMethods).new(self)
  end

  def valid?(*args)
    # Validations are not dependencies
    # TODO we should yell if the user is trying to write
    without_promiscuous { super }
  end

  module ClassMethods
    # all methods are virtual

    def publish(*args, &block)
      options    = args.extract_options!
      attributes = args

      # TODO reject invalid options

      if attributes.present? && self.publish_to && options[:to] && self.publish_to != options[:to]
        raise 'versionned publishing is not supported yet'
      end
      self.publish_to ||= options[:to] || "#{Promiscuous::Config.app}/#{self.name.underscore}"
      @publish_as = options[:as].to_s if options[:as]
      Promiscuous::ZK.ensure_valid_backend unless publish_to =~ /^__promiscuous__\//

      ([self] + descendants).each do |klass|
        # When the user passes :use => [:f1, :f2] for example, operation/mongoid.rb
        # can track f1 and f2 as fields important for the publishing.
        # It's important for virtual attributes. The published_db_fields is global
        # for the entire subclass tree.
        klass.published_db_fields |= [options[:use]].flatten.map(&:to_sym) if options[:use]
        klass.published_db_fields |= attributes.map(&:to_sym) # aliased fields are resolved later
        klass.published_attrs     |= attributes.map(&:to_sym)
      end
    end

    def track_dependencies_of(*attributes)
      ([self] + descendants).each { |klass| klass.tracked_attrs |= attributes }
    end

    def promiscuous_collection_name
      self.name.pluralize.underscore
    end

    def publish_as
      @publish_as || name
    end

    def inherited(subclass)
      super
      subclass.published_attrs = self.published_attrs.dup
      subclass.tracked_attrs   = self.tracked_attrs.dup
      # no copy for published_db_fields
    end

    class None; end
    def promiscuous_missing_record_exception
      None
    end
  end
end
