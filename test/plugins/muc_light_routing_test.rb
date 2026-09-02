require "test_helper"
require "rexml/document"

class MucLightRoutingTest < Minitest::Test
  # Minimal fake client: derive a bare JID and dispatch stanzas to on_stanza.
  class FakeClient
    attr_reader :jid

    def initialize(jid)
      @jid = jid
    end

    def bare_jid
      jid.to_s.split("/", 2).first
    end
  end

  def plugin
    @plugin ||= Xmpp::Plugins::MucLight.new(FakeClient.new("me@example.com"), service_host: "muclight.example.com")
  end

  def stanza(xml, type: "groupchat", from: "room@muclight.example.com/nick")
    root = REXML::Document.new(
      "<message type='#{type}' from='#{from}'><x xmlns='urn:xmpp:muclight:0#affiliations'>" \
      "<version>2</version><prev-version>1</prev-version>" \
      "<user affiliation='member'>bob@example.com</user></x></message>"
    ).root
    root
  end

  def event_stanza(xml)
    REXML::Document.new(xml).root
  end

  def test_affiliation_change_event
    events = []
    plugin.on_affiliation_change { |e| events << e }
    plugin.on_stanza(stanza("<x/>"))
    assert_equal 1, events.length
    assert_equal "room@muclight.example.com", events.first[:room_jid]
    assert_equal "bob@example.com", events.first[:users].first[:jid]
  end

  def test_groupchat_message_event_with_inherited_namespace
    # The <body> carries no xmlns; message payload should still parse.
    events = []
    plugin.on_message { |e| events << e }
    root = REXML::Document.new(
      "<message type='groupchat' from='room@muclight.example.com/nick'><body>hi there</body></message>"
    ).root
    plugin.on_stanza(root)
    assert_equal 1, events.length
    assert_equal "hi there", events.first[:body]
    assert_equal "room@muclight.example.com", events.first[:room_jid]
  end
end
