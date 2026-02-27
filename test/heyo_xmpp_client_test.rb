require "test_helper"

class HeyoXmppClientTest < Minitest::Test
  def test_version_constant_is_defined
    refute_nil HeyoXmppClient::VERSION
  end

  def test_exposes_xmpp_client
    assert_kind_of Class, Xmpp::Client
  end
end
