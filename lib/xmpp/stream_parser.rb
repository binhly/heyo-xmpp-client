require "rexml/document"
require "rexml/parsers/sax2parser"
require "thread"

class XmppStreamParser
  Event = Struct.new(:type, :element, :error)

  # A thread-safe FIFO that supports blocking pop with a timeout so the
  # client can bound how long it waits on the reading thread.
  class TimedQueue
    def initialize
      @mutex = Mutex.new
      @cond = ConditionVariable.new
      @items = []
    end

    def push(item)
      @mutex.synchronize do
        @items << item
        @cond.signal
      end
    end
    alias << push

    # Returns the next item, or nil when +timeout+ seconds elapse with no
    # item available. A nil +timeout+ (or Infinity) blocks indefinitely.
    def pop_with_timeout(timeout)
      @mutex.synchronize do
        if @items.empty?
          return nil if timeout && timeout <= 0
          @cond.wait(@mutex, timeout)
          return nil if @items.empty?
        end
        @items.shift
      end
    end
  end

  def initialize(io, logger: nil)
    @io = io
    @queue = TimedQueue.new
    @logger = logger
    @thread = Thread.new { run }
  end

  # Yields the next parse event. When +timeout+ (seconds) is given and
  # elapses before an event arrives, returns nil instead of blocking forever.
  def next_event(timeout: nil)
    @queue.pop_with_timeout(timeout)
  end

  def stop
    @thread&.kill
    @thread = nil
  end

  private

  class StreamListener
    def initialize(queue, logger)
      @queue = queue
      @logger = logger
      @stack = []
    end

    def start_element(_uri, _localname, qname, attributes)
      element = REXML::Element.new(qname)
      attributes.each { |key, value| element.add_attribute(key, value) }
      if qname == "stream:stream"
        @stack.clear
        @stack << element
        return
      end
      if @stack.empty?
        @stack << element
        return
      end
      @stack.last.add_element(element)
      @stack << element
    end

    def end_element(_uri, _localname, qname)
      return if @stack.empty?
      if qname == "stream:stream"
        @stack.clear
        return
      end
      element = @stack.pop
      if @stack.empty?
        return
      end
      if @stack.length == 1
        @queue << Event.new(:element, element, nil)
      end
    rescue StandardError => e
      @queue << Event.new(:error, nil, e)
      log("Parser end_element error: #{e}")
    end

    def start_document; end

    def end_document; end

    def start_prefix_mapping(_prefix, _uri); end

    def end_prefix_mapping(_prefix); end

    def progress(_position); end

    def characters(text)
      return if @stack.empty?
      @stack.last.add_text(text)
    end

    def cdata(text)
      return if @stack.empty?
      @stack.last.add(REXML::CData.new(text))
    end

    def log(message)
      return unless @logger
      @logger.call(message)
    end
  end

  def run
    listener = StreamListener.new(@queue, @logger)
    parser = REXML::Parsers::SAX2Parser.new(@io)
    parser.listen(listener)
    parser.parse
    @queue << Event.new(:eof, nil, nil)
  rescue StandardError => e
    @queue << Event.new(:error, nil, e)
  end
end
