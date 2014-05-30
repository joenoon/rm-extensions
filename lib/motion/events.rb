module RMExtensions

  module ObjectExtensions

    module Events

      def rmext_events_from_proxy
        @rmext_events_from_proxy ||= EventsFromProxy.new(self)
      end

      def rmext_events_from_proxy?
        !!@rmext_events_from_proxy
      end

      def rmext_events_to_proxy
        @rmext_events_to_proxy ||= EventsToProxy.new(self)
      end

      def rmext_events_to_proxy?
        !!@rmext_events_to_proxy
      end

      # register a callback when an event is triggered on this object.
      def rmext_on(event, opts={}, &block)
        rmext_events_from_proxy.on(event, opts, &block)
      end

      def rmext_now_and_on(event, opts={}, &block)
        rmext_events_from_proxy.now_and_on(event, opts, &block)
      end

      # register a callback when an event is triggered on this object and remove it after it fires once
      def rmext_once(event, opts={}, &block)
        opts[:limit] = 1
        rmext_events_from_proxy.on(event, opts, &block)
      end

      # @model.rmext_off(:fire, self)      # remove :fire in context "self"
      # @model.rmext_off(:fire, &block)    # remove :fire for specific handler
      # @model.rmext_off(:fire)            # remove all :fire in all knowns contexts
      # @model.rmext_off(self)             # remove all events in context "self"
      # @model.rmext_off                   # remove all events in all known contexts
      def rmext_off(event=nil, context=nil, &block)
        if rmext_events_from_proxy?
          rmext_events_from_proxy.off(event, context, &block)
        end
      end

      # remove all event callbacks from other objects in this object's "self"
      def rmext_cleanup(firing_object=nil)
        if rmext_events_to_proxy?
          rmext_events_to_proxy.cleanup(firing_object)
        end
      end

      # trigger an event with value on this object
      def rmext_trigger(event, *values)
        if rmext_events_from_proxy?
          rmext_events_from_proxy.trigger(event, *values)
        end
      end

    end

  end

  # Proxy object used to hold the firing objects that this real object's
  # "self" owns handlers for.
  # Can be used to cleanup all handlers across all firing objects that have
  # the hanlder's owner (Proc#owner) == this real object.
  # Does not need to perform deallocation logic as nothing is retained
  # and the real object will fall out of the cooresponding EventsFromProxy
  # automatically.
  class EventsToProxy

    Dispatch.once do
      @@sync_queue = Dispatch::Queue.new("#{NSBundle.mainBundle.bundleIdentifier}.EventsToProxy.queue1")
    end

    include CommonMethods

    rmext_weak_attr_accessor :weak_object
    
    def initialize(obj)
      self.weak_object = obj
      @has_handlers_for = WeakToStrongHash.new
    end

    def has_handlers_for!(firing_object)
      @@sync_queue.sync do
        if DEBUG_EVENTS
          p "CONTEXT:", weak_object.rmext_object_desc, "LISTENING TO:", firing_object.rmext_object_desc
        end
        @has_handlers_for[firing_object] ||= true
      end
    end

    def cleanup(firing_object=nil)
      @@sync_queue.sync do
        # p "cleanup caller", caller
        if firing_object
          if @has_handlers_for.delete(firing_object)
            if DEBUG_EVENTS
              p "CONTEXT:", weak_object.rmext_object_desc, "UNLISTENING TO:", firing_object.rmext_object_desc
            end
            firing_object.rmext_off(weak_object)
          end
        else
          keys = [] + @has_handlers_for.keys
          while keys.size > 0
            firing_object = keys.shift
            if DEBUG_EVENTS
              p "CONTEXT:", weak_object.rmext_object_desc, "UNLISTENING TO:", firing_object.rmext_object_desc
            end
            firing_object.rmext_off(weak_object)
          end
        end
        true
      end
    end

  end

  # Proxy class used to hold the actual handlers and contexts of handlers.
  # When the real class deallocates, all handlers are removed.
  class EventsFromProxy

    Dispatch.once do
      @@sync_queue = Dispatch::Queue.new("#{NSBundle.mainBundle.bundleIdentifier}.EventsFromProxy.queue1")
      @@async_queue = Dispatch::Queue.new("#{NSBundle.mainBundle.bundleIdentifier}.EventsFromProxy.queue2")
    end

    include CommonMethods

    # def inspect
    #   ka = []
    #   for k in @events.keys
    #     if k.weakref_alive?
    #       ka << [ k, @events[k] ]
    #     end
    #   end
    #   "#{super} (#{ka.inspect})"
    # end

    rmext_weak_attr_accessor :weak_object

    def initialize(obj)
      self.weak_object = obj
      @events = WeakToStrongHash.new
      if DEBUG_EVENTS
        p "CREATED #{className}: #{weak_object.rmext_object_desc}"
      end
    end

    # def rmext_dealloc
    #   off
    #   super
    # end

    def on(event, opts={}, &block)
      @@sync_queue.sync do
        next if event.nil? || block.nil?
        event = event.to_s
        context = block.owner
        block.weak!
        if DEBUG_EVENTS
          p "ON:", event, "opts:", opts
        end
        @events[context] ||= {}
        @events[context][event] ||= {}
        @events[context][event][block] = opts.dup
        @events[context][event][block][:limit] ||= -1
        # i.e.: controller/view has handlers for object
        context.rmext_events_to_proxy.has_handlers_for!(weak_object)
      end
    end

    def now_and_on(event, opts={}, &block)
      rmext_block_on_main_q(block)
      on(event, opts, &block)
    end

    def off(event=nil, context=nil, &block)
      @@sync_queue.sync do
        if event.is_a?(String) || event.is_a?(Symbol)
          event = event.to_s
          if block
            context = block.owner
            if context_events = @events[context]
              if context_event_blocks = context_events[event]
                if DEBUG_EVENTS
                  p "remove the one block for the event in the blocks #owner", "EVENT:", event, "CONTEXT:", context.rmext_object_desc, "BLOCKS:", context_event_blocks
                end
                context_event_blocks.delete block
              end
            end
          elsif context
            if context_events = @events[context]
              if DEBUG_EVENTS
                p "remove all handlers for the given event in the given context", "EVENT:", event, "CONTEXT:", context.rmext_object_desc, "BLOCKS:", context_events
              end
              context_events.delete(event)
            end
          else
            contexts = @events.keys
            while context = contexts.pop
              if context_events = @events[context]
                if DEBUG_EVENTS
                  p "remove all handlers for the event in all contexts known", "EVENT:", event, "CONTEXT:", context.rmext_object_desc, "BLOCKS:", context_events
                end
                context_events.delete event
              end
            end
          end
        elsif event
          context = event
          if DEBUG_EVENTS
            p "event is really a context. remove all events and handlers for the context", "CONTEXT:", context.rmext_object_desc, "BLOCKS:", @events[context]
          end
          @events.delete(context)
        else
          if DEBUG_EVENTS
            p "remove everything on", weak_object.rmext_object_desc
          end
          @events.clear
        end
        nil
      end
    end

    def trigger(event, *values)
      # if DEBUG_EVENTS
      #   p "TRIGGER:", event, values #, "@events", @events
      # end
      @@async_queue.async do
        next if event.nil?
        event = event.to_s
        contexts = @events.keys
        # if DEBUG_EVENTS
        #   p "contexts:", contexts
        # end
        while context = contexts.pop
          # if DEBUG_EVENTS
          #   p "look for:", context #, "in @events:", @events
          # end
          if context_events = @events[context]
            # if DEBUG_EVENTS
            #   p "context_events:", context_events
            # end
            if event_blocks = context_events[event]
              blocks = event_blocks.keys
              if DEBUG_EVENTS
                p "TRIGGER:", event, "OBJECT:", weak_object.rmext_object_desc, "CONTEXT:", context.rmext_object_desc, "BLOCKS SIZE:", blocks.size
              end
              while blocks.size > 0
                block = blocks.shift
                limit = event_blocks[block][:limit]
                queue = event_blocks[block][:queue]
                if queue == :async
                  queue = @@async_queue
                elsif queue == :main
                  queue = Dispatch::Queue.main
                end
                queue ||= Dispatch::Queue.main
                # if queue == Dispatch::Queue.main
                #   p "MAIN:", event, "OBJECT:", weak_object.rmext_object_desc, "CONTEXT:", context.rmext_object_desc
                # end
                if limit == 1
                  # off
                  if DEBUG_EVENTS
                    p "LIMIT REACHED:", event, "OBJECT:", weak_object.rmext_object_desc, "CONTEXT:", context.rmext_object_desc
                  end
                  off(event, context, &block)
                elsif limit > 1
                  @@sync_queue.sync do
                    event_blocks[block][:limit] -= 1
                  end
                end
                context.retain
                queue.barrier_async do
                  block.call(*values)
                  context.autorelease
                end
              end
            end
          end
        end
      end
      nil
    end

  end

end
Object.send(:include, ::RMExtensions::ObjectExtensions::Events)
