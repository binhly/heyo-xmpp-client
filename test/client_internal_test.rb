require "test_helper"

class ClientInternalTest < Minitest::Test
  def build_client(jid: "user@example.com/resource", **opts)
    Xmpp::Client.new(jid: jid, password: "pw", **opts)
  end

  def test_parse_jid_strips_resource_from_domain_and_user
    client = build_client
    assert_equal "example.com", client.send(:instance_variable_get, :@domain)
    assert_equal "user", client.send(:instance_variable_get, :@user)
    assert_equal "user@example.com", client.bare_jid
  end

  def test_parse_jid_invalid
    assert_raises(ArgumentError) { build_client(jid: "nope") }
  end

  def test_connect_timeout_default
    client = build_client
    assert_equal 10, client.send(:instance_variable_get, :@connect_timeout)
    assert_equal 30, client.send(:instance_variable_get, :@read_timeout)
  end

  def test_parse_jid_without_resource_still_works
    client = build_client(jid: "bob@example.org")
    assert_equal "example.org", client.send(:instance_variable_get, :@domain)
    assert_equal "bob", client.send(:instance_variable_get, :@user)
    assert_equal "bob@example.org", client.bare_jid
  end

  def test_element_matches_stream_features_by_namespace
    helper = Object.new.extend(Xmpp::XmlHelpers)
    features = helper.child_by_name(
      REXML::Document.new("<stream:stream xmlns:stream='http://etherx.jabber.org/streams'><stream:features/></stream:stream>").root,
      "features"
    )
    client = build_client
    assert client.send(:element_matches?, features, "stream:features")
  end
end
