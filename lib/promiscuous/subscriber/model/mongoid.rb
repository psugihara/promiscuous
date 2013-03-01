module Promiscuous::Subscriber::Model::Mongoid
  extend ActiveSupport::Concern
  include Promiscuous::Subscriber::Model::Base

  def __promiscuous_update(payload, options={})
    super
    # The return value tells if the parent should assign the attribute
    !self.embedded? || options[:old_value] != self
  end

  module ClassMethods
    def subscribe(*args, &block)
      super
      return unless block

      begin
        @in_subscribe_block = true
        block.call
      ensure
        @in_subscribe_block = false
      end
    end

    def self.subscribe_on(method, options={})
      define_method(method) do |name, *args, &block|
        super(name, *args, &block)
        if @in_subscribe_block
          name = args.last[:as] if args.last.is_a?(Hash) && args.last[:as]
          subscribe(name)
        end
      end
    end

    subscribe_on :field
    subscribe_on :embeds_one
    subscribe_on :embeds_many

    def __promiscuous_missing_record_exception
      Mongoid::Errors::DocumentNotFound
    end
  end

  class EmbeddedMany
    include Promiscuous::Subscriber::Model::Base

    subscribe :from => '__promiscuous__/embedded_many'

    def __promiscuous_update(payload, options={})
      old_embeddeds = options[:old_value]
      new_embeddeds = payload.attributes

      # XXX Reordering is not supported

      # find all updatable docs
      new_embeddeds.each do |new_e|
        old_e = old_embeddeds.select { |e| e.id.to_s == new_e['id'] }.first
        if old_e
          new_e['existed'] = true
          old_e.instance_variable_set(:@keep, true)

          payload = Promiscuous::Subscriber::Payload.new(new_e)
          old_e.__promiscuous_update(payload, :old_value => old_e)
        end
      end

      # delete all the old ones
      old_embeddeds.each do |old_e|
        old_e.destroy unless old_e.instance_variable_get(:@keep)
      end

      # create all the new ones
      new_embeddeds.reject { |new_e| new_e['existed'] }.each do |new_e|
        payload = Promiscuous::Subscriber::Payload.new(new_e)
        new_e_instance = payload.model. __promiscuous_fetch_new(payload.id)
        new_e_instance.__promiscuous_update(payload)
        options[:parent].__send__(old_embeddeds.metadata[:name]) << new_e_instance
      end

      false
    end

    def self.__promiscuous_fetch_new(id)
      new
    end
  end
end
