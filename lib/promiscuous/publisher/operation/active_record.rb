raise "activerecord > 3.2.12 please" unless Gem.loaded_specs['activerecord'].version >= Gem::Version.new('3.2.12')


class ActiveRecordOperationWrapper < Promiscuous::Publisher::Operation::Base
end

class ActiveRecord::Relation
  attr_accessor :promiscuous_operation
end

# module ActiveRecord::AttributeMethods
#   module Read
#     alias_method :highjacked_read, :read_attribute

#     def read_attribute(attr_name)
#       # Promiscuous::Publisher::Operation::Base.new(:operation => :read).commit()
#       puts "read #{attr_name}"
#       highjacked_read(attr_name)
#     end
#   end
# end


module ActiveRecord::QueryMethods
  alias_method :where_hijack, :where
  def where(opts = :chain, *rest)
    relation = where_hijack(opts, *rest)

    # Get dependencies for the query.
    # This is a hack and doesn't get all of the fields in all cases.
    if (opts.is_a?(Hash))
      fields = opts.keys
      fields.delete('id') unless fields.nil?
      fields.delete('publisher_id') unless fields.nil?

      # Pass the fields to the Relation so that we can mark them as read.
      relation.promiscuous_operation = ActiveRecordOperationWrapper.new()
      pro = OpenStruct.new({:tracked_dependencies => []})
      relation.promiscuous_operation.instance = OpenStruct.new({:promiscuous => pro})
      relation.promiscuous_operation.instance.promiscuous.tracked_dependencies = fields unless fields.nil? || fields.empty?
    end

    relation
  end
end

module ActiveRecord::Calculations
  alias_method :count_hijack, :count
  def count(column_name = nil, options = {})
    unless promiscuous_operation.nil?
      # Tell promiscuous the fields were read.
      klass.all.each do |instance|
        op = promiscuous_operation.clone()
        op.instance = instance.id
        op.operation = :read
        op.commit()
      end
    end
    count_hijack(column_name, options)
  end
end