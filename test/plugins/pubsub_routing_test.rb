require "test_helper"
require "rexml/document"

class PubsubRoutingTest < Minitest::Test
  class FakeClient
    attr_reader :jid
    def initialize(jid) = @jid = jid
    def bare_jid = jid.to_s.split("/", 2).first
  end

  def plugin
    @plugin ||= Xmpp::Plugins::Pubsub.new(FakeClient.new("me@example.com"), service_host: "pubsub.example.com")
  end

  def test_item_published_event_with_payload
    events = []
    plugin.on_item_published { |e| events << e }
    root = REXML::Document.new(
      "<message from='pubsub.example.com'>" \
      "<event xmlns='http://jabber.org/protocol/pubsub#event'><items node='blog'>" \
      "<item id='a' publisher='me@example.com'><entry xmlns='http://www.w3.org/2005/Atom'>Hi</entry></item>" \
      "</items></event></message>"
    ).root
    plugin.on_stanza(root)
    assert_equal 1, events.length
    assert_equal "blog", events.first[:node]
    assert_equal "a", events.first[:item_id]
    assert_match(/<entry/, events.first[:payload_xml])
  end

  def test_event_with_inherited_namespace_is_ignored_without_event_ns
    # Namespace must actually resolve; a <message> with an <event> element in a
    # foreign namespace should not be treated as a pubsub event.
    events = []
    plugin.on_item_published { |e| events << e }
    root = REXML::Document.new(
      "<message from='pubsub.example.com'><event xmlns='urn:other:thing'><items node='blog'><item id='x'/></items></event></message>"
    ).root
    plugin.on_stanza(root)
    assert_empty events
  end
end
