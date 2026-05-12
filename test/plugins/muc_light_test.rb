require "test_helper"

class MucLightTest < Minitest::Test
  FakeClient = Struct.new(:jid)

  def test_plugin_class_loads
    assert_kind_of Class, Xmpp::Plugins::MucLight
  end

  def test_plugin_id_is_muc_light
    assert_equal :muc_light, Xmpp::Plugins::MucLight.plugin_id
  end

  def test_default_service_host_is_derived_from_jid
    plugin = Xmpp::Plugins::MucLight.new(FakeClient.new("user@example.com"))
    assert_equal "muclight.example.com", plugin.service_host
  end

  def test_service_host_override_wins
    plugin = Xmpp::Plugins::MucLight.new(
      FakeClient.new("user@example.com"),
      service_host: "groups.example.com"
    )
    assert_equal "groups.example.com", plugin.service_host
  end

  def test_event_registration_returns_plugin_for_chaining
    plugin = Xmpp::Plugins::MucLight.new(FakeClient.new("user@example.com"))
    Xmpp::Plugins::MucLight::EVENTS.each do |event|
      result = plugin.public_send("on_#{event}") { |_| }
      assert_same plugin, result, "on_#{event} should return self"
    end
  end
end
