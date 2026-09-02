require "test_helper"
require "stringio"

class XmppStreamParserTest < Minitest::Test
  def parse_stream(xml)
    parser = XmppStreamParser.new(StringIO.new(xml))
    events = []
    loop do
      ev = parser.next_event
      break if ev.type == :eof
      events << ev
    end
    parser.stop
    events
  end

  def test_parses_basic_stanzas_and_stream_features
    xml = <<~XMPP
      <stream:stream to='example.com' xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams'>
        <stream:features><starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'><required/></starttls></stream:features>
        <message to='me@example.com' from='alice@example.com/res' type='chat'><body>Hello &amp; bye</body></message>
        <presence/>
        <iq type='result' id='bind_1'><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'><jid>me@example.com/ruby</jid></bind></iq>
      </stream:stream>
    XMPP

    events = parse_stream(xml)
    elements = events.select { |e| e.type == :element }.map(&:element)

    assert_equal 4, elements.length
    assert_equal %w[features iq message presence], elements.map(&:name).sort

    features = elements.find { |e| e.name == "features" }
    assert_equal "stream:features", features.expanded_name
    assert_equal Xmpp::XmlHelpers::StreamNamespace, features.namespace
    assert_equal "urn:ietf:params:xml:ns:xmpp-tls", features.elements["starttls"].namespace

    message = elements.find { |e| e.name == "message" }
    assert_equal "Hello & bye", message.elements["body"].text

    iq = elements.find { |e| e.name == "iq" }
    assert_equal "bind_1", iq.attributes["id"]
    assert_equal "me@example.com/ruby", iq.elements["bind"].elements["jid"].text
  end

  def test_namespace_resolution_handles_inherited_default_namespace
    # <x> is nested but inherits no explicit xmlns; the effective namespace is
    # resolved from the parent, so namespaced? matches it.
    xml = <<~XMPP
      <stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams'>
        <message type='groupchat' from='room@muclight.example.com/nick'>
          <x xmlns='urn:xmpp:muclight:0#affiliations'><version>1</version><user affiliation='owner'>me@example.com</user></x>
          <x xmlns='urn:xmpp:muclight:0#configuration'><subject>hi</subject></x>
          <body>hi</body>
        </message>
      </stream:stream>
    XMPP

    events = parse_stream(xml)
    message = events.find { |e| e.type == :element }.element
    xs = []
    message.elements.each("x") { |x| xs << x }

    helper = Object.new.extend(Xmpp::XmlHelpers)
    assert_equal 2, xs.length
    assert helper.namespaced?(xs[0], "urn:xmpp:muclight:0#affiliations")
    assert helper.namespaced?(xs[1], "urn:xmpp:muclight:0#configuration")
  end

  def test_timeout_returns_nil_instead_of_blocking
    read_io, write_io = IO.pipe
    parser = XmppStreamParser.new(read_io)
    # No data pushed yet; a short timeout must return nil rather than hang.
    assert_nil parser.next_event(timeout: 0.05)
    # Now push data and confirm the same parser still delivers the event.
    write_io.write("<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams'><message><body>hi</body></message></stream:stream>")
    write_io.close
    ev = parser.next_event(timeout: 2)
    refute_nil ev
    assert_equal :element, ev.type
    assert_equal "message", ev.element.name
    parser.stop
  end
end
