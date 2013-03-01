require 'active_support/core_ext'

module Promiscuous
  def self.require_for(gem, file)
    require gem
    require file
  rescue LoadError
  end

  require 'promiscuous/autoload'
  require_for 'rails',  'promiscuous/railtie'
  require_for 'resque', 'promiscuous/resque'


  extend Promiscuous::Autoload
  autoload :Common, :Publisher, :Subscriber, :Observer, :Worker, :Ephemeral,
           :CLI, :Error, :Loader, :AMQP, :Redis, :ZK, :Config, :DSL, :Key,
           :Convenience, :Dependency, :Middleware

  extend Promiscuous::DSL

  Object.__send__(:include, Promiscuous::Convenience)

  class << self
    def configure(&block)
      Config.configure(&block)
    end

    [:debug, :info, :error, :warn, :fatal].each do |level|
      define_method(level) do |msg|
        Promiscuous::Config.logger.__send__(level, "[promiscuous] #{msg}")
      end
    end

    def connect
      AMQP.connect
      Redis.connect
      ZK.connect
    end

    def disconnect
      AMQP.disconnect
      Redis.disconnect
      ZK.disconnect
    end

    def healthy?
      AMQP.ensure_connected
      Redis.ensure_connected
      ZK.ensure_connected
    rescue
      false
    else
      true
    end

    def transaction(*args, &block)
      Publisher::Transaction.open(*args, &block)
    end
  end

  at_exit { self.disconnect rescue nil }
end
