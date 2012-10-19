module Promiscuous::Publisher::Envelope
  extend ActiveSupport::Concern

  def payload
    { :hostname  => Socket.gethostname, :payload => super }
  end
end
