require_relative "test_helper"
require_relative "support/fake_xmpp_server"

# End-to-end lifecycle tests: the real Xmpp::Client drives a scripted server
# over real TCP (and real TLS where the scenario upgrades). No client
# internals are stubbed or set via instance_variable_set.
class ClientLifecycleTest < Minitest::Test
  JID = "jill@localhost"
  PASSWORD = "knowink"
  PLAIN_BLOB = Base64.strict_encode64("\0jill\0#{PASSWORD}").freeze

  # A plugin that ATTEMPTS SASL on every connection and reports failure —
  # the only way to reach the client's one-shot @plain_fallback_disabled
  # guard (TokenReconnection clears its tokens after a rejection and
  # declines instead of failing twice).
  class AlwaysFailingSaslPlugin < Xmpp::Plugin
    def sasl_authenticate(_client, features)
      return nil unless features.elements["mechanisms"]
      false
    end
  end

  # A plugin whose on_connect sends an IQ over the (possibly dying)
  # connection, driving the nested-reconnect guard scenario.
  class IqOnConnectPlugin < Xmpp::Plugin
    # Errors observed by on_connect across every instance; the nested
    # reconnect guard surfaces here as "Reconnect already in progress".
    OBSERVED_ERRORS = []

    def on_connect
      client.request_iq(
        id: "on_connect_iq",
        xml: "<iq type='get' id='on_connect_iq'><ping xmlns='urn:xmpp:ping'/></iq>",
        allow_reconnect: true,
        timeout: 2
      )
    rescue Xmpp::Client::TimeoutError, Xmpp::Error => e
      OBSERVED_ERRORS << "#{e.class}: #{e.message}"
      nil
    end
  end

  def setup
    @server = FakeXmppServer.new
  end

  def teardown
    @client&.disconnect rescue nil
    @server&.stop
  end

  # --- scripts -------------------------------------------------------------

  # Full negotiation: header/features (+STARTTLS), PLAIN auth, bind, session.
  # Ends with the connection held open unless +hold_open: false+.
  def full_handshake_script(starttls:, mechanisms: ["PLAIN"], fail_plain: false, hold_open: true)
    lambda do |conn|
      conn.expect(/<stream:stream to='localhost'/)
      conn.send(FakeXmppServer::XML_DECL + FakeXmppServer::HEADER + FakeXmppServer.features(mechanisms: mechanisms, starttls: starttls))
      if starttls
        conn.expect(/<starttls/)
        conn.send("<proceed xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>")
        conn.start_tls_as_server
        conn.expect(/<stream:stream to='localhost'/)
        conn.send(FakeXmppServer::HEADER + FakeXmppServer.features(mechanisms: mechanisms))
      end
      conn.expect(/<auth [^>]*mechanism='PLAIN'>#{PLAIN_BLOB}</)
      if fail_plain
        conn.send(FakeXmppServer.sasl_failure)
      else
        conn.send("<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>")
        conn.expect(/<stream:stream to='localhost'/)
        conn.send(FakeXmppServer::HEADER + FakeXmppServer.features(mechanisms: [], bind: true))
        conn.expect(/<iq type='set' id='bind_1'/)
        conn.send(FakeXmppServer.bind_result("bind_1", "#{JID}/ruby"))
        conn.expect(/<iq type='set' id='sess_1'/)
        conn.send(FakeXmppServer.iq_result("sess_1"))
        conn.hold if hold_open
      end
    end
  end

  # Connection where X-OAUTH is offered and rejected with a SASL failure.
  def xoauth_rejected_script
    lambda do |conn|
      conn.expect(/<stream:stream to='localhost'/)
      conn.send(FakeXmppServer::XML_DECL + FakeXmppServer::HEADER + FakeXmppServer.features(starttls: true, mechanisms: %w[X-OAUTH PLAIN]))
      conn.expect(/<starttls/)
      conn.send("<proceed xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>")
      conn.start_tls_as_server
      conn.expect(/<stream:stream to='localhost'/)
      conn.send(FakeXmppServer::HEADER + FakeXmppServer.features(mechanisms: %w[X-OAUTH PLAIN]))
      conn.expect(/<auth [^>]*mechanism='X-OAUTH'/)
      conn.send(FakeXmppServer.sasl_failure)
      conn.drain_until_close
    end
  end

  # --- tests ---------------------------------------------------------------

  def test_full_happy_path_with_starttls_plain_bind_session
    @server.on_connection(&full_handshake_script(starttls: true))
    with_trusted_ca do
      client = build_client(reconnect: false)
      client.connect
      assert_equal "#{JID}/ruby", client.full_jid
      client.disconnect
    end
    @server.wait_for_scripts
  end

  def test_starttls_failure_raises_protocol_error
    @server.on_connection do |conn|
      conn.expect(/<stream:stream to='localhost'/)
      conn.send(FakeXmppServer::XML_DECL + FakeXmppServer::HEADER + FakeXmppServer.features(starttls: true))
      conn.expect(/<starttls/)
      conn.send("<failure xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>")
      conn.expect(/<stream:stream/) rescue nil
    end
    client = build_client(reconnect: false)
    error = assert_raises(Xmpp::ProtocolError) { client.connect }
    assert_includes error.message, "STARTTLS"
    @server.wait_for_scripts
  end

  def test_starttls_required_but_not_offered_never_sends_password
    client_bytes = nil
    @server.on_connection do |conn|
      conn.expect(/<stream:stream to='localhost'/)
      conn.send(FakeXmppServer::XML_DECL + FakeXmppServer::HEADER + FakeXmppServer.features(starttls: false))
      conn.expect(/<stream:stream/) rescue nil
      client_bytes = conn.client_bytes.dup
    end
    client = build_client(reconnect: false)
    assert_raises(Xmpp::ProtocolError) { client.connect }
    @server.wait_for_scripts
    refute_nil client_bytes
    refute_includes client_bytes, PASSWORD
    refute_includes client_bytes, PLAIN_BLOB
  end

  def test_plain_auth_failure_raises_authentication_error_with_element
    @server.on_connection(&full_handshake_script(starttls: true, fail_plain: true))
    with_trusted_ca do
      client = build_client(reconnect: false)
      error = assert_raises(Xmpp::AuthenticationError) { client.connect }
      assert_equal "not-authorized", error.failure_element&.children&.first&.name
    end
    @server.wait_for_scripts
  end

  def test_token_auth_rejection_falls_back_to_plain_on_new_stream
    @server.on_connection(&xoauth_rejected_script)
    @server.on_connection(&full_handshake_script(starttls: true))
    with_trusted_ca do
      client = build_client(reconnect: false)
      plugin = client.use(Xmpp::Plugins::TokenReconnection, auto_request: false)
      plugin.update_tokens(access_token: "expired-token")
      client.connect
      assert_equal "#{JID}/ruby", client.full_jid
      client.disconnect
    end
    @server.wait_for_scripts
  end

  def test_second_sasl_rejection_raises_fallback_disabled
    2.times do
      @server.on_connection do |conn|
        conn.expect(/<stream:stream to='localhost'/)
        conn.send(FakeXmppServer::XML_DECL + FakeXmppServer::HEADER + FakeXmppServer.features(starttls: true))
        conn.expect(/<starttls/)
        conn.send("<proceed xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>")
        conn.start_tls_as_server
        conn.expect(/<stream:stream to='localhost'/)
        conn.send(FakeXmppServer::HEADER + FakeXmppServer.features(mechanisms: %w[X-OAUTH PLAIN]))
        # The plugin declines without writing, and the client reconnects
        # or raises "fallback disabled" before ever sending <auth>.
        conn.drain_until_close
      end
    end
    with_trusted_ca do
      client = build_client(reconnect: false)
      client.use(AlwaysFailingSaslPlugin)
      error = assert_raises(Xmpp::AuthenticationError) { client.connect }
      assert_includes error.message, "fallback disabled"
      # connect raised after opening conn2; close it so the server script's
      # drain_until_close sees EOF instead of timing out.
      client.disconnect rescue nil
    end
    @server.wait_for_scripts
  end

  # A stream drop mid-IQ loses the in-flight IQ (there is no XEP-0198
  # resumption to replay it); the caller gets a TimeoutError while the
  def test_stream_drop_mid_iq_reconnects_and_later_iq_completes
    # Connection 1: full handshake, then drop as soon as the IQ arrives.
    @server.on_connection do |conn|
      full_handshake_script(starttls: true, hold_open: false).call(conn)
      conn.expect(/<iq /, timeout: 10)
      conn.close # hard drop while the client waits on the IQ result
    end
    # Connection 2 (the reconnect): handshake, then answer the next IQ.
    @server.on_connection do |conn|
      full_handshake_script(starttls: true, hold_open: false).call(conn)
      matched = conn.expect(/<iq [^>]*type='get' [^>]*id='after_drop'/, timeout: 10)
      conn.send(FakeXmppServer.iq_result(matched[/id='([^']+)'/, 1]))
      conn.hold(seconds: 10)
    end
    with_trusted_ca do
      client = build_client(reconnect: true, reconnect_base_interval: 0.05)
      client.connect
      error = assert_raises(Xmpp::Client::TimeoutError) do
        client.request_iq(
          id: "drop_1",
          xml: "<iq type='get' id='drop_1'><ping xmlns='urn:xmpp:ping'/></iq>",
          timeout: 2
        )
      end
      assert_includes error.message, "Timed out"
      # The reconnect replaced the transport behind the timeout.
      result = client.request_iq(
        id: "after_drop",
        xml: "<iq type='get' id='after_drop'><ping xmlns='urn:xmpp:ping'/></iq>",
        timeout: 5
      )
      assert_equal "result", result.attributes["type"]
      client.disconnect
    end
    @server.wait_for_scripts
  end

  # A plugin whose on_connect sends an IQ that dies with the connection
  # during a reconnect must hit the @reconnecting guard ("Reconnect already
  # in progress") instead of deadlocking on the reconnect mutex; the outer
  # reconnect loop then retries and completes.
  def test_nested_reconnect_guard_raises_instead_of_deadlocking
    # Connection 1: handshake, drop on the first IQ.
    @server.on_connection do |conn|
      full_handshake_script(starttls: true, hold_open: false).call(conn)
      conn.expect(/<iq /, timeout: 10)
      conn.close
    end
    # Connection 2: reconnect target; dies right after the session is set.
    @server.on_connection do |conn|
      full_handshake_script(starttls: true, hold_open: false).call(conn)
      conn.close
    end
    # Connection 3: final reconnect; answers every IQ with its own id.
    @server.on_connection do |conn|
      full_handshake_script(starttls: true, hold_open: false).call(conn)
      loop do
        matched = conn.expect(/<iq [^>]*type='get' [^>]*id='([^']+)'[^>]*>/, timeout: 10)
        conn.send(FakeXmppServer.iq_result(matched[/id='([^']+)'/, 1]))
      end
    rescue RuntimeError, EOFError
      conn.hold(seconds: 5) rescue nil
    end
    logs = []
    with_trusted_ca do
      client = build_client(reconnect: true, reconnect_base_interval: 0.05, logger: ->(m) { logs << m; STDERR.puts "CLIENT: #{m}" })
      client.use(IqOnConnectPlugin)
      client.connect
      # The EOF that kills conn2 sits in the parser queue until a consumer
      # reads it; the first attempt may therefore fail with a write error
      # before the reconnect replaces the transport.
      result = nil
      10.times do
        begin
          result = client.request_iq(
            id: "final_check",
            xml: "<iq type='get' id='final_check'><ping xmlns='urn:xmpp:ping'/></iq>",
            timeout: 5
          )
          break
        rescue Xmpp::Client::TimeoutError, Xmpp::Error
          sleep 0.2
        end
      end
      assert_equal "result", result&.attributes&.fetch("type", nil)&.to_s
      assert IqOnConnectPlugin::OBSERVED_ERRORS.any? { |m| m.include?("Reconnect already in progress") },
             "nested reconnect must hit the guard, observed: #{IqOnConnectPlugin::OBSERVED_ERRORS.inspect}"
      client.disconnect
    end
    @server.wait_for_scripts
  end

  def test_silent_server_ping_liveness_surfaces_error_on_consumer_thread
    @server.on_connection(&full_handshake_script(starttls: true))
    with_trusted_ca do
      client = build_client(reconnect: false, ping_interval: 0.5)
      client.connect
      error = nil
      listener = Thread.new do
        begin
          client.listen { |_xml| }
        rescue StandardError => e
          error = e
        end
      end
      listener.join(15)
      refute listener.alive?, "listen thread should have terminated"
      assert error, "consumer thread must observe the dead connection"
    end
    @server.wait_for_scripts
  end

  # --- helpers -------------------------------------------------------------

  def build_client(reconnect:, ping_interval: 0, reconnect_base_interval: 1, logger: nil)
    Xmpp::Client.new(
      jid: JID,
      password: PASSWORD,
      host: @server.host,
      port: @server.port,
      use_tls: :starttls,
      reconnect: reconnect,
      reconnect_base_interval: reconnect_base_interval,
      reconnect_max_attempts: 10,
      ping_interval: ping_interval,
      connect_timeout: 5,
      read_timeout: 5,
      logger: logger
    ).tap { |c| @client = c }
  end

  # Points the client's certificate store (set_default_paths reads
  # SSL_CERT_FILE at TLS time) at the harness CA. Restores afterwards.
  def with_trusted_ca
    ENV["SSL_CERT_FILE"] = @server.ca_path
    yield
  ensure
    ENV.delete("SSL_CERT_FILE")
  end
end
