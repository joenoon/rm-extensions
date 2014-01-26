module RMExtensions

  def self.debug?
    !!@debug
  end

  def self.debug!(bool=true)
    @debug = bool
  end

  # LongTask encapsulates beginBackgroundTaskWithExpirationHandler/endBackgroundTask:
  #
  # RMExtensions::BackgroundTask.new("my long task") do |task|
  #   do_something_long
  #   task.end!
  # end
  #
  # RMExtensions::BackgroundTask.new("my long task") do |task|
  #   do_something_long_async do
  #     # later this long task finishes...
  #     task.end!
  #   end
  # end
  #
  class LongTask
    attr_accessor :bgTask, :desc

    def self.time_remaining
      UIApplication.sharedApplication.backgroundTimeRemaining
    end

    def self.when_all_complete(&block)
      rmext_on_main_q do
        if ::RMExtensions::LongTask.outstanding_tasks.size.zero?
          rmext_block_on_main_q(block)
        else
          rmext_once(::RMExtensions::LongTask, :all_complete) do |opts|
            block.call
          end
        end
      end
    end

    def self.outstanding_queue
      Dispatch.once do
        @outstanding_queue = Dispatch::Queue.new("#{NSBundle.mainBundle.bundleIdentifier}.outstanding.LongTask")
      end
      @outstanding_queue
    end

    def self.outstanding_tasks
      Dispatch.once do
        @outstanding_tasks = []
      end
      @outstanding_tasks
    end

    # RMExtensions::BackgroundTask.verbose("my long task") { |task| task.end! }
    def self.verbose(desc=nil, &block)
      _creator(desc, true, true, &block)
    end

    # RMExtensions::BackgroundTask.create("my long task") { |task| task.end! }
    def self.create(desc=nil, &block)
      _creator(desc, false, true, &block)
    end

    def self.internal(desc=nil, &block)
      _creator(desc, false, false, &block)
    end

    def self._creator(desc=nil, verbose=false, tracking=true, &block)
      x = new(desc, verbose, tracking)
      block.weak!.call(x)
      x
    end

    def self.reset_outstanding_tasks!
      ::RMExtensions::LongTask.outstanding_queue.sync do
        size = ::RMExtensions::LongTask.outstanding_tasks.size
        if size > 0
          p "WARNING: reset_outstanding_tasks! (was: #{size})"
          ::RMExtensions::LongTask.outstanding_tasks.removeAllObjects
        end
      end
    end

    def initialize(desc=nil, verbose=false, tracking=true)
      @verbose = verbose
      @tracking = tracking
      @desc = "#{rmext_object_desc} #{desc}"
      @bgTask = UIApplication.sharedApplication.beginBackgroundTaskWithExpirationHandler(lambda do
        p "ERROR: #{@desc} didn't call #end! in time!"
        __end!
      end)
      if ::RMExtensions.debug? || @verbose
        p "CREATED: #{@desc}"
      end
      if @tracking
        ::RMExtensions::LongTask.outstanding_queue.sync do
          ::RMExtensions::LongTask.outstanding_tasks << self
        end
      end
      self
    end

    def end!
      if ::RMExtensions.debug? || @verbose
        p "SUCCESS: #{@desc} ended successfully."
      end
      __end!
    end

    def __end!
      if @tracking
        ::RMExtensions::LongTask.outstanding_queue.sync do
          ::RMExtensions::LongTask.outstanding_tasks.delete(self)
          ::RMExtensions::LongTask.internal do |internal_task|
            rmext_on_main_q do
              if ::RMExtensions::LongTask.outstanding_tasks.size.zero?
                ::RMExtensions::LongTask.rmext_trigger(:all_complete)
              end
              internal_task.end!
            end
          end
        end
      end
      if @bgTask && @bgTask != UIBackgroundTaskInvalid
        UIApplication.sharedApplication.endBackgroundTask(@bgTask)
        @bgTask = UIBackgroundTaskInvalid
      end
    end

    def dealloc
      if ::RMExtensions.debug?
        p "DEALLOC: #{@desc}"
      end
      super
    end

  end

  module ObjectExtensions

    module Util

      def rmext_object_desc
        "#<#{self.className}:0x#{'%x' % (self.object_id)}(#{self.object_id})>"
      end

      # Raises an exception when called from a thread other than the main thread.
      # Good for development and experimenting.
      def rmext_assert_main_thread!
        raise "This method must be called on the main thread." unless NSThread.currentThread.isMainThread
      end

      # Shortcut to instance_variable_get and instance_variable_get:
      # 1 arg for instance_variable_get
      # 2 args for instance_variable_set
      def rmext_ivar(*args)
        if args.size == 1
          instance_variable_get("@#{args[0]}")
        elsif args.size == 2
          instance_variable_set("@#{args[0]}", args[1])
        else
          raise "rmext_ivar called with invalid arguments: #{args.inspect}"
        end
      end

      def rmext_nil_instance_variables!
        ivars = [] + instance_variables
        while ivar = ivars.pop
          instance_variable_set(ivar, nil)
        end
        true
      end

      def rmext_assign_debug_labels_to_ivars!
        ivars = [] + instance_variables
        while ivar = ivars.pop
          val = instance_variable_get(ivar)
          val.rmext_ivar(:debug_label, ivar)
        end
        true
      end

      # call the block immediately if called on the main thread,
      # otherwise call it async on the main queue
      def rmext_inline_or_on_main_q(&block)
        if NSThread.currentThread.isMainThread
          block.call
        else
          rmext_on_main_q(&block)
        end
      end

      # call the block immediately if called on the main thread with the given args,
      # otherwise call it async on the main queue.
      # silently ignores nil blocks to avoid if !block.nil? checks, useful for async callbacks
      # that optionally take a callback
      def rmext_block_on_main_q(block, *args)
        unless block.nil?
          rmext_inline_or_on_main_q do
            block.call(*args)
          end
        end
      end

      ### EXPERIMENTAL

      # takes a unique_id, run_immediately bool, and block
      # if run_immediately is true, the block is executed immediately and not counted
      # on the next run loop, the block will be called IF it has been counted at least once.
      # examples:
      #
      # # CALLED will be printed twice.  Onces immediately, and once on the next runloop:
      # 10.times do
      #   rmext_debounce_on_next_runloop(:my_unique_id, true) do
      #     p "CALLED"
      #   end
      # end
      #
      # # CALLED will be printed once, on the next runloop:
      # 10.times do
      #   rmext_debounce_on_next_runloop(:my_unique_id, false) do
      #     p "CALLED"
      #   end
      # end
      #
      # useful for queuing up something that should happen on the next runloop,
      # but not every time its called.  for example, reloadData.  the goal was
      # to get a similar behavior to how setNeedsDisplay/setNeedsLayout scheduled
      # display/layout rendering on the next UI runloop pass
      #
      def rmext_debounce_on_next_runloop(unique_id, run_immediately, &block)
        Thread.current["rmext_debounce_on_next_runloop"] ||= {}
        lookup = Thread.current["rmext_debounce_on_next_runloop"]
        if lookup.key?(unique_id)
          lookup[unique_id][0] += 1
        else
          lookup[unique_id] = [ 0, lambda do
            if (debounced_times = lookup[unique_id][0]) > 0
              # p "we have", debounced_times, "debounced_times queued for unique_id", unique_id
              block.call
            else
              # p "no debounced_times queued for unique_id", unique_id
            end
            lookup.delete(unique_id)
          end ]
          if run_immediately
            block.call
          else
            lookup[unique_id][0] += 1
          end
          # p NSRunLoop.currentRunLoop, NSRunLoop.currentRunLoop.currentMode, lookup[unique_id][1]
          NSRunLoop.currentRunLoop.performSelector('call', target:lookup[unique_id][1], argument:nil, order:0, modes:[NSRunLoop.currentRunLoop.currentMode])
        end
      end

      def rmext_debounce_selector_on_next_runloop(selector, run_immediately)
        Thread.current["rmext_debounce_selector_on_next_runloop"] ||= {}
        lookup = Thread.current["rmext_debounce_selector_on_next_runloop"]
        if lookup.key?(selector)
          lookup[selector] += 1
        else
          lookup[selector] = 0
          if run_immediately
            send(selector)
          else
            lookup[selector] += 1
          end
          # p NSRunLoop.currentRunLoop, NSRunLoop.currentRunLoop.currentMode, self, selector, lookup[selector]
          block = lambda do
            if (debounced_times = lookup[selector]) > 0
              # p "we have", debounced_times, "debounced_times queued for", self, selector
              send(selector)
            else
              # p "no debounced_times queued for", self, selector
            end
            lookup.delete(selector)
          end
          NSRunLoop.currentRunLoop.performSelector('call', target:block, argument:nil, order:0, modes:[NSRunLoop.currentRunLoop.currentMode])
        end
      end

      # more typical debouncing behavior
      def rmext_debounced(method_name, seconds, *args)
        new_method_name = "#{method_name}_#{seconds}"
        unless respond_to?(new_method_name)
          self.class.send(:define_method, new_method_name) do |*xargs|
            xargs.unshift(method_name)
            send(*xargs)
          end
        end
        args.unshift(new_method_name)
        NSObject.cancelPreviousPerformRequestsWithTarget(self, selector:"rmext_dispatch__send__", object:args)
        performSelector("rmext_dispatch__send__", withObject:args, afterDelay:seconds)
      end

      # used internally by `rmext_debounced`
      def rmext_dispatch__send__(*args)
        send(*args)
      end

    end

  end

end
Object.send(:include, ::RMExtensions::ObjectExtensions::Util)
