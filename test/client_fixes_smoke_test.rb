require "test_helper"

# Smoke tests for bug-fix regressions that don't need a scripted server:
# they exercise the public API surface only. Every scenario that required
# stubbing private methods (open_transport, cleanup_connection, parser
# internals) moved to client_lifecycle_test.rb, which drives the real
# state machine end-to-end against a scripted server.
class ClientFixesSmokeTest < Minitest::Test
  def build_client
    Xmpp::Client.new(jid: "user@example.com", password: "pw", use_tls: :starttls)
  end

  # send_raw must raise the gem's error type (not a raw socket error) when
  # there is no transport.
  def test_send_raw_raises_when_not_connected
    client = build_client
    assert_raises(Xmpp::Error) { client.send_message(to: "a@b", body: "hi") }
    assert_raises(Xmpp::Error) { client.send_presence }
  end

  # connect/disconnect cycles on the public surface must leave the client
  # reusable: disconnect is safe to call twice, and connect failure through
  # an unreachable port raises the gem's error types.
  def test_disconnect_is_idempotent
    client = build_client
    client.disconnect
    client.disconnect
    assert_raises(Xmpp::Error) { client.send_message(to: "a@b", body: "hi") }
  end

  def test_connect_to_unreachable_port_raises_xmpp_error
    client = Xmpp::Client.new(
      jid: "user@example.com", password: "pw",
      host: "127.0.0.1",
      port: 1, # nothing listens here
      use_tls: :starttls, reconnect: false,
      connect_timeout: 1, read_timeout: 1
    )
    error = assert_raises(StandardError) { client.connect }
    assert_kind_of Xmpp::Error, error
  end
end
