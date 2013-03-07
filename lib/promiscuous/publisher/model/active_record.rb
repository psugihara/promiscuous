module Promiscuous::Publisher::Model::ActiveRecord
  extend ActiveSupport::Concern
  include Promiscuous::Publisher::Model::Base

  require 'promiscuous/publisher/operation/active_record'

  included do
    around_create  { |&block| promiscuous.sync(:operation => :create,  &block) }
    around_update  { |&block| promiscuous.sync(:operation => :update,  &block) }
    around_destroy { |&block| promiscuous.sync(:operation => :destroy, &block) }
    after_find     { |&block| promiscuous.sync(:operation => :read, &block) }
  end

  module ClassMethods

    # TODO DRY this up with the publisher side
    def publish(*args, &block)
      super
      return unless block

      begin
        @in_publish_block = true
        block.call
      ensure
        @in_publish_block = false
      end
    end

    def self.publish_on(method, options={})
      define_method(method) do |name, *args, &block|
        super(name, *args, &block)
        if @in_publish_block
          name = args.last[:as] if args.last.is_a?(Hash) && args.last[:as]
          publish(name)
        end
      end
    end

    publish_on :field

    def __promiscuous_missing_record_exception
      ActiveRecord::RecordNotFound
    end
  end
end
