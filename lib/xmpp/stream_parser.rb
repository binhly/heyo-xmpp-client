require "rexml/document"
require "rexml/parsers/sax2parser"
require "thread"

class XmppStreamParser
  Event = Struct.new(:type, :element, :error)

  def initialize(io, logger: nil)
    @io = io
    @queue = Queue.new
    @logger = logger
    @thread = Thread.new { run }
  end

  def next_event
    @queue.pop
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
