require "test_helper"

class ClientFixesSmokeTest < Minitest::Test
  # --- helpers -------------------------------------------------------------

  def build_features_element(starttls: true, mechanisms: [])
    mech = mechanisms.map { |m| "<mechanism>#{m}</mechanism>" }.join
    starttls_el = starttls ? "<starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>" : ""
    doc = REXML::Document.new(
      "<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams'>" \
      "<stream:features>#{starttls_el}<mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>#{mech}</mechanisms></stream:features>" \
      "</stream:stream>"
    )
    doc.root.children.first
  end

  class FakeSocket
    attr_reader :written
    def initialize = @written = +""
    def write(str) = (@written << str)
    def close = nil
  end

  # Installs a scripted XmppStreamParser that feeds canned events and records
  # how many times the transport was re-opened.
  class ScriptedParser < XmppStreamParser
    def initialize(events)
      @events = events.dup
      super(FakeSocket.new)
    end

    def next_event(timeout: nil)
      @events.shift || Event.new(:eof, nil, nil)
    end
  end

  def build_client
    Xmpp::Client.new(jid: "user@example.com", password: "pw", use_tls: :starttls)
  end

  # --- 2: plaintext guard ---------------------------------------------------

  def test_connect_once_raises_when_starttls_not_offered
    client = build_client
    client.instance_variable_set(:@socket, FakeSocket.new)
    client.instance_variable_set(:@parser, ScriptedParser.new([
      XmppStreamParser::Event.new(:element, build_features_element(starttls: false, mechanisms: ["PLAIN"]), nil)
    ]))
    client.stub(:open_transport, nil) do
      client.stub(:cleanup_connection, nil) do
        error = assert_raises(Xmpp::Error) { client.send(:connect_once) }
        assert_match(/refusing to authenticate over plaintext/, error.message)
      end
    end
  end

  # --- 1: token-reject falls back to PLAIN on a fresh stream ----------------

  def test_token_failure_restarts_stream_then_plain_authenticates
    client = build_client
    client.instance_variable_set(:@socket, FakeSocket.new)
    client.instance_variable_set(:@parser, ScriptedParser.new([
      XmppStreamParser::Event.new(:element, build_features_element(starttls: false, mechanisms: ["PLAIN"]), nil)
    ]))
    client.stub(:open_transport, nil) do
      client.stub(:cleanup_connection, nil) do
        client.stub(:open_and_negotiate_stream, nil) do
          client.stub(:bind_resource, nil) do
            client.stub(:start_session, nil) do
              client.stub(:mark_connected, nil) do
                sasl_calls = []
                plugin = Object.new
                def plugin.sasl_authenticate(client, _features)
                  # First call: token attempt consumed (returns false). Second
                  # call, after the stream restart: nil so the client falls
                  # through to PLAIN.
                  calls = client.instance_variable_get(:@sasl_calls)
                  if client.instance_variable_get(:@plain_fallback_disabled)
                    calls << :plain_path
                    nil
                  else
                    calls << :token_path
                    false
                  end
                end
                client.instance_variable_set(:@sasl_calls, sasl_calls)
                client.instance_variable_set(:@plugin_manager, plugin)
                client.define_singleton_method(:sasl_authenticate) do |mechanism:, payload:|
                  sasl_calls << "PLAIN:#{mechanism}"
                  REXML::Document.new("<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>").root
                end
                client.send(:authenticate)
                assert_includes sasl_calls, "PLAIN:PLAIN"
                assert_equal [:token_path, :plain_path], sasl_calls.grep(Symbol)
              end
            end
          end
        end
      end
    end
  end

  def test_second_token_failure_raises_instead_of_looping
    client = build_client
    client.instance_variable_set(:@plain_fallback_disabled, true)
    plugin = Object.new
    def plugin.sasl_authenticate(_c, _f) = false
    client.instance_variable_set(:@plugin_manager, plugin)
    client.stub(:open_transport, nil) do
      client.stub(:cleanup_connection, nil) do
        client.stub(:open_and_negotiate_stream, nil) do
          error = assert_raises(Xmpp::Error) { client.send(:authenticate) }
          assert_match(/fallback disabled/, error.message)
        end
      end
    end
  end

  # --- 5: send_raw raises when disconnected ---------------------------------

  def test_send_raw_raises_when_not_connected
    client = build_client
    assert_raises(Xmpp::Error) { client.send_message(to: "a@b", body: "hi") }
  end

  # --- 7: stop_ping kills the thread; no shared ping state ------------------

  def test_ping_thread_is_stopped_by_stop_ping
    client = build_client
    client.instance_variable_set(:@ping_interval, 60)
    client.instance_variable_set(:@connected, true)
    client.stub(:send_ping, ->(_) { raise "must not ping" }) do
      client.stub(:wait_for_liveness, nil) do
        client.send(:start_ping)
        thread = client.instance_variable_get(:@ping_thread)
        refute_nil thread
        sleep 0.2
        client.send(:stop_ping)
        thread.join(1)
        refute thread.alive?
      end
    end
  end

  def test_ping_liveness_closes_socket_when_silent
    client = build_client
    client.instance_variable_set(:@ping_interval, 0.4)
    client.instance_variable_set(:@connected, true)
    client.instance_variable_set(:@socket, FakeSocket.new)
    client.instance_variable_set(:@parser, ScriptedParser.new([]))
    client.stub(:send_ping, nil) do
      client.send(:start_ping)
      deadline = Time.now + 5
      sleep 0.05 while !client.instance_variable_get(:@socket).nil? && Time.now < deadline
      assert_nil client.instance_variable_get(:@socket), "socket should be closed by liveness check"
      refute client.instance_variable_get(:@connected)
      client.send(:stop_ping)
    end
  end

  def test_ping_liveness_survives_when_server_responds
    client = build_client
    client.instance_variable_set(:@ping_interval, 0.4)
    client.instance_variable_set(:@connected, true)
    client.instance_variable_set(:@socket, FakeSocket.new)
    client.instance_variable_set(:@parser, ScriptedParser.new([]))
    client.stub(:send_ping, nil) do
      client.send(:start_ping)
      # Simulate server traffic by bumping the parser's activity timestamp.
      deadline = Time.now + 2
      while Time.now < deadline
        client.instance_variable_get(:@parser).instance_variable_set(
          :@last_activity, Process.clock_gettime(Process::CLOCK_MONOTONIC)
        )
        sleep 0.1
      end
      assert client.instance_variable_get(:@socket), "socket should remain open while server responds"
      assert client.instance_variable_get(:@connected)
      client.send(:stop_ping)
    end
  end
end
