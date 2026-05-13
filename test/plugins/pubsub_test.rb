require "test_helper"

class PubsubTest < Minitest::Test
  FakeClient = Struct.new(:jid)

  def test_plugin_class_loads
    assert_kind_of Class, Xmpp::Plugins::Pubsub
  end

  def test_plugin_id_is_pubsub
    assert_equal :pubsub, Xmpp::Plugins::Pubsub.plugin_id
  end

  def test_default_service_host_is_derived_from_jid
    plugin = Xmpp::Plugins::Pubsub.new(FakeClient.new("user@example.com"))
    assert_equal "pubsub.example.com", plugin.service_host
  end

  def test_service_host_override_wins
    plugin = Xmpp::Plugins::Pubsub.new(
      FakeClient.new("user@example.com"),
      service_host: "ps.example.com"
    )
    assert_equal "ps.example.com", plugin.service_host
  end

  def test_event_registration_returns_plugin_for_chaining
    plugin = Xmpp::Plugins::Pubsub.new(FakeClient.new("user@example.com"))
    Xmpp::Plugins::Pubsub::EVENTS.each do |event|
      result = plugin.public_send("on_#{event}") { |_| }
      assert_same plugin, result, "on_#{event} should return self"
    end
  end
end
