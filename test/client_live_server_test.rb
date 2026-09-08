require_relative "test_helper"

# Live integration tests against the real MongooseIM server on
# localhost:5222 (user jill@localhost). Skipped when the server is not
# reachable so the suite stays green in CI without infrastructure.
#
# The server uses a self-signed "MongooseIM Fake CA"; the certificate is
# extracted from the running container into /tmp by these tests when needed
# (SSL_CERT_FILE).
class ClientLiveServerTest < Minitest::Test
  HOST = "localhost"
  PORT = 5222
  JID = "jill@localhost"
  PASSWORD = "knowink"
  CA = "/tmp/mongooseim_ca.pem"

  def server_available?
    Socket.tcp(HOST, PORT, connect_timeout: 2).close
    true
  rescue SystemCallError
    false
  end

  def with_live_client(password: PASSWORD, **options)
    skip "MongooseIM not reachable on #{HOST}:#{PORT}" unless server_available?
    ensure_ca
    client = Xmpp::Client.new(
      jid: JID,
      password: password,
      host: HOST,
      port: PORT,
      use_tls: :starttls,
      reconnect: false,
      connect_timeout: 5,
      read_timeout: 5,
      **options
    )
    yield client
  ensure
    client&.disconnect rescue nil
  end

  def ensure_ca
    return if File.exist?(CA) && !ENV["SSL_CERT_FILE"].nil?
    # Pull the Fake CA out of the running container; fall back to extracting
    # the leaf (verification then fails, which the test reports clearly).
    system("docker", "cp", "mongooseim-1:/usr/lib/mongooseim/priv/ssl/cacert.pem", CA) ||
      system("bash", "-c", "echo | openssl s_client -connect #{HOST}:#{PORT} -starttls xmpp 2>/dev/null | openssl x509 > #{CA}")
    ENV["SSL_CERT_FILE"] = CA
  end

  def test_connects_binds_and_round_trips_an_iq
    with_live_client do |client|
      client.connect
      assert_equal JID, client.bare_jid
      assert_match(/\A#{Regexp.escape(JID)}\//, client.full_jid)

      id = client.next_iq_id("live")
      result = client.request_iq(
        id: id,
        xml: "<iq type='get' id='#{id}'><query xmlns='http://jabber.org/protocol/disco#info'/></iq>",
        timeout: 5
      )
      assert_equal "result", result.attributes["type"].to_s
      assert result.elements["query"], "disco#info response must carry <query>"
    end
  end

  def test_wrong_password_raises_xmpp_error
    with_live_client(password: "definitely-not-the-password") do |client|
      error = assert_raises(StandardError) { client.connect }
      assert_kind_of Xmpp::Error, error
    end
  end

  def test_send_message_and_presence_round_trip
    with_live_client do |client|
      client.connect
      client.send_presence(status: "integration test")
      # Message to self; MongooseIM delivers it back to the same session.
      received = Queue.new
      listener = Thread.new do
        begin
          client.listen { |xml| received << xml if xml.to_s.include?("roundtrip") }
        rescue StandardError
          nil
        end
      end
      client.send_message(to: JID, body: "roundtrip-#{Process.pid}")
      got = received.pop(timeout: 10) rescue nil
      listener.kill
      assert got, "expected the echoed message to arrive"
    end
  end
end
