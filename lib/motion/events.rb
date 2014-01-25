module RMExtensions

  module ObjectExtensions

    module Events

      def rmext_events_proxy
        @rmext_events_proxy ||= EventsProxy.new(self)
      end

      def rmext_events_proxy?
        !@rmext_events_proxy.nil?
      end

      # register a callback when an event is triggered on this object.
      def rmext_on(object, event, &block)
        object.rmext_events_proxy.on(event, limit:-1, inContext:self, withBlock:block)
      end

      def rmext_now_and_on(object, event, &block)
        object.rmext_events_proxy.now_and_on(event, inContext:self, withBlock:block)
      end

      # register a callback when an event is triggered on this object and remove it after it fires once
      def rmext_once(object, event, &block)
        object.rmext_events_proxy.on(event, limit:1, inContext:self, withBlock:block)
      end

      # remove a specific callback for an event on object
      def rmext_off(object, event, &block)
        if object.rmext_events_proxy?
          object.rmext_events_proxy.off(event, inContext:self, withBlock:block)
        end
      end

      # remove all event callbacks on this object,
      # remove all event callbacks from other objects in this object's "self"
      def rmext_cleanup
        if @rmext_events_proxy
          @rmext_events_proxy.cleanup
        end
      end

      ### these get called on the object: ie. @model.rmext_off_all

      # remove all event callbacks on this object
      def rmext_off_all
        if @rmext_events_proxy
          @rmext_events_proxy.off_all
        end
      end

      # trigger an event with value on this object
      def rmext_trigger(event, value=nil)
        if @rmext_events_proxy
          @rmext_events_proxy.trigger(event, value)
        end
      end

    end

  end

  class EventResponse
    attr_accessor :context, :value, :target, :event
  end

  # Proxy class used to hold the actual listeners and contexts where listening
  # and watches for the real class intended to hold the observation to be
  # deallocated, so the events can be cleaned up.
  class EventsProxy

    def initialize(obj)
      @weak_object = WeakRef.new(obj)
      @events = NSMapTable.weakToStrongObjectsMapTable
      @listenings = NSHashTable.weakObjectsHashTable
      if ::RMExtensions.debug?
        p "CREATED EventsProxy: #{@weak_object.rmext_object_desc}"
      end
    end

    def dealloc
      @did_dealloc = true
      cleanup
      if ::RMExtensions.debug?
        p "DEALLOC EventsProxy: #{@weak_object.rmext_object_desc}"
      end
      super
    end

    def cleanup
      off_all
      off_all_context
      true
    end

    def on(event, limit:limit, inContext:context, withBlock:block)
      return if event.nil? || block.nil?
      event = event.to_s
      context ||= self.class
      unless context_events = @events.objectForKey(context)
        context_events = {}
        @events.setObject(context_events, forKey:context)
      end
      unless context_event_blocks = context_events.objectForKey(event)
        context_event_blocks = {}
        context_events.setObject(context_event_blocks, forKey:event)
      end
      block.weak!
      context_event_blocks[block] = limit
      # i.e.: controller/view listening_to model
      context.rmext_events_proxy.listening_to(@weak_object)
    end

    # this is called in the reverse direction than normal
    def listening_to(object)
      if ::RMExtensions.debug?
        p "CONTEXT:", @weak_object.rmext_object_desc, "LISTENING TO:", object.rmext_object_desc
      end
      @listenings.addObject(object)
    end

    def now_and_on(event, inContext:context, withBlock:block)
      rmext_inline_or_on_main_q do
        res = EventResponse.new
        res.context = context
        res.value = nil
        res.target = @weak_object
        res.event = event
        block.call(res)
      end
      on(event, limit:-1, inContext:context, withBlock:block)
    end

    def off(event, inContext:context, withBlock:block)
      return if event.nil? || block.nil?
      event = event.to_s
      context ||= self.class
      return unless context_events = @events.objectForKey(context)
      return unless context_event_blocks = context_events.objectForKey(event)
      context_event_blocks.delete block
      nil
    end

    def off_all
      @events.removeAllObjects
    end

    def off_context(context)
      @events.setObject(nil, forKey:context)
    end

    def off_all_context
      while object = @listenings.anyObject
        if ::RMExtensions.debug?
          p "CONTEXT:", @weak_object.rmext_object_desc, "UNLISTENING TO:", object.rmext_object_desc
        end
        @listenings.removeObject(object)
        if object.rmext_events_proxy?
          object.rmext_events_proxy.off_context(@weak_object)
        end
      end
    end

    def trigger(event, value)
      rmext_inline_or_on_main_q do
        next if @did_dealloc
        next if event.nil?
        event = event.to_s
        keyEnumerator = @events.keyEnumerator
        contexts = []
        while context = keyEnumerator.nextObject
          contexts.push context
        end
        while context = contexts.pop
          if context_events = @events.objectForKey(context)
            if event_blocks = context_events[event]
              blocks = event_blocks.keys
              if ::RMExtensions.debug?
                p "TRIGGER:", event, "OBJECT:", @weak_object.rmext_object_desc, "CONTEXT:", context.rmext_object_desc, "BLOCKS SIZE:", blocks.size
              end
              while block = blocks.pop
                limit = event_blocks[block]
                res = EventResponse.new
                res.context = context
                res.value = value
                res.target = @weak_object
                res.event = event
                block.call(res)
                if limit == 1
                  # off
                  if ::RMExtensions.debug?
                    p "LIMIT REACHED:", event, "OBJECT:", @weak_object.rmext_object_desc, "CONTEXT:", context.rmext_object_desc
                  end
                  off(event, inContext:context, withBlock:block)
                elsif limit > 1
                  context_events[block] -= 1
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
