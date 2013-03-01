class Promiscuous::Publisher::Operation::Base
  Transaction = Promiscuous::Publisher::Transaction
  class TryAgain < RuntimeError; end

  attr_accessor :operation, :operation_ext, :multi,
                :old_instance, :instance, :missed,
                :dependencies, :commited_dependencies

  def initialize(options={})
    # XXX instance is not always an instance, it can be a selector
    # representation.
    @instance      = options[:instance]
    @operation     = options[:operation]
    @operation_ext = options[:operation_ext]
    @multi         = options[:multi]
  end

  def read?
    operation == :read
  end

  def write?
    !read?
  end

  def multi?
    !!@multi
  end

  def single?
    !@multi
  end

  def failed?
    !@completed
  end

  def missed?
    !!@missed
  end

  def update_dependencies_read
    futures = nil
    Promiscuous::Redis.pipelined do
      # This read/write split counters ensure maximal parallelization on the
      # subscriber side: we want to be able to execute the read dependencies
      # in any order as it doesn't change the behavior.
      @dependencies.each do |dep|
        Promiscuous::Redis.incr(dep.key(:pub).join('rw').for(:redis))
      end

      futures = @dependencies.map do |dep|
        [dep, Promiscuous::Redis.get(dep.key(:pub).join('w').for(:redis))]
      end
    end
    futures.each { |dep, version| dep.version = version.value.to_i }
  end

  def update_dependencies_write
    futures = nil
    Promiscuous::Redis.pipelined do
      futures = @dependencies.map do |dep|
        [dep, Promiscuous::Redis.incr(dep.key(:pub).join('rw').for(:redis))]
      end
    end
    futures.each { |dep, version| dep.version = version.value.to_i }

    # All the dependencies are locked, so we don't have races,
    # but maybe it would be faster using a lua script?
    Promiscuous::Redis.pipelined do
      @dependencies.each do |dep|
        Promiscuous::Redis.set(dep.key(:pub).join('w').for(:redis), dep.version)
      end
    end
  end

  def update_dependencies
    self.read? ? update_dependencies_read : update_dependencies_write
    @commited_dependencies = @dependencies
  end

  def lock_dependencies(&block)
    # MultiLock takes care of deadlock issues with respect to ordering, so we
    # don't need extra logic in here.
    Promiscuous::ZK::MultiLock.new.tap do |locks|
      @dependencies.each do|dep|
        locks.add(dep.key(:pub).for(:zk), :mode => read? ? :shared : :exclusive)
      end
    end.acquire(&block)
  end

  def lookup_dependencies
    if read?
      # We want to use the smallest subset that we can depend on when doing reads
      # tracked_dependencies comes sorted: the smallest subset to the
      # largest for maximum performance on the subscriber side. The good thing
      # is that :id always comes first
      best_dependency = @instance.promiscuous.tracked_dependencies.first
      unless best_dependency
        raise Promiscuous::Error::Dependency.new(:operation => self)
      end
      [best_dependency]
    else
      # We need to lock and update all the dependencies because they any other
      # readers can see our write through any one of our dependencies.

      # Note that tracked_dependencies will not return the id dependency if it
      # doesn't exist which only happen for create operations. But that's fine
      # because the race with concurrent updates cannot happen. It's a good
      # thing because we want to be able to create instance with an auto
      # generated id.
      @instance.promiscuous.tracked_dependencies
    end
  end

  def ensure_up_to_date_dependencies
    new_dependencies = lookup_dependencies

    if @dependencies != new_dependencies
      # Because the instance has changed, we are now holding the wrong
      # dependencies (or a non efficient one for a read -- we probably
      # just got upgraded to an id dependency).
      @dependencies = new_dependencies
      false
    end
    true
  end

  def reload_instance
    # We make sure to leave @instance intact if the fetch returns nothing to
    # improve error messages.
    instance = without_promiscuous { fetch_instance }
    if instance
      @instance = instance
    else
      @missed = true
      nil
    end
  end

  # --- the following methods can be overridden if needed --- #

  def _commit(transaction, &db_operation)
    # @instance is already set when entering the commit method. It's not
    # necessarily a proper instance, as it can represent any selector with a
    # {:field => value} hash type.
    @dependencies = lookup_dependencies

    begin
      result = nil
      lock_dependencies do
        if operation != :create && single?
          # We want to reload the instance to make sure we have all the locked
          # dependencies that we need.
          # If the selector doesn't fetch any instance, the query has no effect
          # so we can bypass it as if nothing happened.
          return nil unless reload_instance

          # If we have stale dependencies locked (because of the instance
          # fetch), or have the opportunity to get a better dependency for a
          # read, then we retry.
          raise TryAgain unless ensure_up_to_date_dependencies

          # We got through, we are now holding a specific document. We need to
          # make sure the db_operation will operate on it.
          use_id_selector
        end

        result = db_operation.call(self)

        if operation == :create
          # For auto generated ids, we must have a valid id to have the
          # proper dependencies.
          @dependencies = lookup_dependencies
        end

        update_dependencies

        # This will be used to generate the payload.
        # Note that the instance will not change as the user doesn't have
        # access to our own private copy.
        @old_instance = @instance
        @instance = fetch_instance_after_update if operation == :update
      end

      result
    rescue TryAgain
      # TODO We should do something if we are going in a livelock, but it's a
      # bit complicated to put something robust in place.
      retry
    end
  end

  def ensure_valid_transaction
    transaction = Transaction.current
    # We wrap all writes in transactions if the user doesn't want to deal with
    # them. It can be used in the development console.
    unless transaction
      if Promiscuous::Config.use_transactions
        raise Promiscuous::Error::MissingTransaction if write?
      else
        # The user doesn't want to deal with transactions, so we'll use our own.
        transaction = Transaction.new 'anonymous'
      end
    end

    yield(transaction)
  end

  def commit(&db_operation)
    db_operation ||= proc {}
    return db_operation.call if Transaction.disabled
    return db_operation.call if !Transaction.current && read?

    ensure_valid_transaction do |transaction|
      begin
        _commit(transaction, &db_operation).tap { @completed = true }
      ensure
        transaction.add_operation(self)
        # TODO We commit immediately for now. It works with mongoid, but it's
        # a very different story with ActiveRecord transactions.
        transaction.commit if write? && @completed
      end
    end
  end

  def fetch_instance
    # This method is overridden to use the original query selector.
    # Not used in the case of a create operation.
    @instance
  end

  def use_id_selector
    # to be overridden to use the {:id => @instance.id} selector.
  end

  def fetch_instance_after_update
    # TODO we should use find_and_modify to skip this query
    fetch_instance
  rescue Exception => e
    # TODO We are writing to the log file a stale instance, not great for a log replay.
    raise Promiscuous::Error::Publisher.new(e, :instance => @instance, :out_of_sync => true)
  end
end
