require "socket"
require "openssl"
require "base64"
require "rexml/document"
require "thread"
require "securerandom"
require "timeout"

require_relative "stream_parser"
require_relative "plugin_manager"
require_relative "xml_helpers"

module Xmpp
  class Client
    include Xmpp::XmlHelpers
    # Raised when a bounded wait (connect / IQ / element / read) times out
    # instead of blocking forever.
    TimeoutError = Class.new(Xmpp::Error)


    StreamHeader = %(<?xml version='1.0'?>\n<stream:stream to='%{domain}' xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' version='1.0'>)

    def initialize(jid:, password:, host: nil, port: 5222, use_tls: :starttls, resource: "ruby", logger: nil,
                   reconnect: true, reconnect_max_attempts: nil, reconnect_base_interval: 1,
                   reconnect_max_interval: 30, ping_interval: 60,
                   connect_timeout: 10, read_timeout: 30)
      @jid = jid
      @password = password
      @host = host
      @port = port
      @use_tls = use_tls
      @resource = resource
      @logger = logger
      @socket = nil
      @parser = nil
      @reconnect = reconnect
      @reconnect_max_attempts = reconnect_max_attempts
      @reconnect_base_interval = reconnect_base_interval
      @reconnect_max_interval = reconnect_max_interval
      @ping_interval = ping_interval
      @ping_thread = nil
      @connect_timeout = connect_timeout
      @read_timeout = read_timeout
      @reconnect_mutex = Mutex.new
      @write_mutex = Mutex.new
      @reconnecting = false
      @domain, @user = parse_jid(jid)
      @bare_jid = "#{@user}@#{@domain}"
      @full_jid = nil
      @last_stream_features = nil
      @connected = false
      @plugin_manager = Xmpp::PluginManager.new(logger: @logger)
    end

    attr_reader :full_jid, :jid, :bare_jid

    def connect
      connect_once
      start_ping
      self
    end

    def disconnect
      stop_ping
      stop_parser
      mark_disconnected
      return unless @socket
      send_raw("</stream:stream>")
      @socket.close
      @socket = nil
    end

    def use(plugin_class, **options)
      @plugin_manager.register(plugin_class, self, **options)
    end

    def plugin(id)
      @plugin_manager.fetch(id)
    end

    def plugins
      @plugin_manager.all
    end

    def send_message(to:, body:)
      stanza = "<message to='#{escape_attr(to)}' type='chat'><body>#{escape_text(body)}</body></message>"
      send_raw(stanza)
    end

    def send_presence(status: nil)
      stanza = if status
        "<presence><status>#{escape_text(status)}</status></presence>"
      else
        "<presence/>"
      end
      send_raw(stanza)
    end

    def request_iq(id:, xml:, allow_reconnect: true, timeout: @read_timeout)
      send_raw(xml)
      wait_for_iq(id, allow_reconnect: allow_reconnect, timeout: timeout)
    end

    def next_iq_id(prefix)
      "#{prefix}_#{SecureRandom.hex(4)}"
    end

    def sasl_authenticate(mechanism:, payload:)
      send_raw("<auth xmlns='urn:ietf:params:xml:ns:xmpp-sasl' mechanism='#{escape_attr(mechanism)}'>#{payload}</auth>")
      wait_for_element(name: ["success", "failure"], allow_reconnect: false)
    end

    def read_stanza
      element = next_stanza_element
      element&.to_s
    end

    def listen
      loop do
        xml = read_stanza
        yield xml if xml
      end
    end

    private

    def mark_connected
      return if @connected
      @connected = true
      @plugin_manager.on_connect
    end

    def mark_disconnected(error: nil)
      return unless @connected
      @connected = false
      @plugin_manager.on_disconnect(error: error)
    end

    def dispatch_incoming(element)
      return unless @connected
      @plugin_manager.on_stanza(element)
    end

    def open_stream
      send_raw(StreamHeader % { domain: escape_attr(@domain) })
    end

    def start_tls
      send_raw("<starttls xmlns='#{StartTlsNamespace}'/>")
      response = wait_for_element(name: ["proceed", "failure"], allow_reconnect: false)
      if response.name == "failure"
        raise Error, "STARTTLS negotiation failed: server sent <failure/>"
      end
      stop_parser
      wrap_socket_with_tls
    end

    def wrap_socket_with_tls
      ctx = OpenSSL::SSL::SSLContext.new
      ctx.set_params # Defaults to secure settings
      ctx.verify_mode = OpenSSL::SSL::VERIFY_PEER
      ctx.cert_store = OpenSSL::X509::Store.new
      ctx.cert_store.set_default_paths
      ssl = OpenSSL::SSL::SSLSocket.new(@socket, ctx)
      ssl.hostname = @host || @domain # SNI
      ssl.sync_close = true
      Timeout.timeout(@connect_timeout) { ssl.connect }
      @socket = ssl
      log("TLS negotiation successful")
    end

    def authenticate
      plugin_result = @plugin_manager.sasl_authenticate(self, @last_stream_features)
      return if plugin_result == true
      # A plugin returned false because a token attempt failed (e.g. expired).
      # Do NOT fall back to PLAIN over the same stream: the SASL exchange for
      # the token was already consumed and most servers close the stream on
      # auth failure. Restart the stream, then authenticate with PLAIN on it.
      if plugin_result == false
        raise Error, "Token auth rejected and password fallback disabled" if @plain_fallback_disabled
        @plain_fallback_disabled = true
        log("Token auth rejected; restarting stream for PLAIN retry")
        cleanup_connection
        open_transport
        open_and_negotiate_stream
        authenticate
        return
      end
      auth = Base64.strict_encode64("\0#{@user}\0#{@password}")
      response = sasl_authenticate(mechanism: "PLAIN", payload: auth)
      raise Error, "SASL authentication failed" if response.name == "failure"
    end

    def bind_resource
      iq = "<iq type='set' id='bind_1'><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'><resource>#{escape_text(@resource)}</resource></bind></iq>"
      send_raw(iq)
      response = wait_for_iq("bind_1", allow_reconnect: false)
      bind = response.elements["bind"]
      @full_jid = bind&.elements["jid"]&.text
    end

    def start_session
      iq = "<iq type='set' id='sess_1'><session xmlns='urn:ietf:params:xml:ns:xmpp-session'/></iq>"
      send_raw(iq)
      wait_for_iq("sess_1", allow_reconnect: false)
    end

    def connect_once
      @plain_fallback_disabled = false
      cleanup_connection
      open_transport
      open_and_negotiate_stream
      if @use_tls == :starttls && features_supports_starttls?(@last_stream_features)
        start_tls
        setup_parser
        open_and_negotiate_stream
      elsif @use_tls == :starttls
        # STARTTLS was requested but the server does not offer it; sending the
        # password (even PLAIN-encoded) over cleartext TCP is never safe to do
        # silently.
        raise Error,
              "STARTTLS required but not offered by server; refusing to authenticate over plaintext"
      end
      authenticate
      open_and_negotiate_stream
      bind_resource
      start_session
      mark_connected
    end

    # Establish the raw or TLS transport and the initial parser/socket state.
    def open_transport
      # Socket.tcp supports connect_timeout on all supported Ruby versions;
      # TCPSocket.new only gained the keyword in Ruby 3.4.
      @socket = Socket.tcp(@host || @domain, @port, connect_timeout: @connect_timeout)
      log("Connected to #{@host || @domain}:#{@port}")
      wrap_socket_with_tls if @use_tls == :always
      setup_parser
    end

    # Send the stream header and wait for and record stream features. After
    # STARTTLS the server re-issues features over the new TLS stream.
    def open_and_negotiate_stream
      open_stream
      @last_stream_features = wait_for_element(name: "stream:features", allow_reconnect: false)
      @plugin_manager.on_stream_features(@last_stream_features)
    end

    def cleanup_connection
      mark_disconnected
      stop_ping
      stop_parser
      if @socket
        @socket.close
        @socket = nil
      end
    end

    def setup_parser
      stop_parser
      @parser = XmppStreamParser.new(@socket, logger: @logger)
    end

    def stop_parser
      return unless @parser
      @parser.stop
      @parser = nil
    end

    def features_supports_starttls?(features)
      features.elements.any? do |element|
        element.name == "starttls" && namespaced?(element, StartTlsNamespace)
      end
    end

    def wait_for_element(name:, allow_reconnect:, timeout: @read_timeout)
      names = Array(name)
      loop do
        element = next_element(allow_reconnect: allow_reconnect, timeout: timeout)
        raise TimeoutError, "Timed out after #{timeout}s waiting for element #{names.join('/')}" if element.nil?
        return element if names.any? { |n| element_matches?(element, n) }
      end
    end

    def wait_for_iq(id, allow_reconnect:, timeout: @read_timeout)
      loop do
        element = next_element(allow_reconnect: allow_reconnect, timeout: timeout)
        raise TimeoutError, "Timed out after #{timeout}s waiting for IQ #{id}" if element.nil?
        next unless element.name == "iq"
        return element if element.attributes["id"] == id
      end
    end

    def next_element(allow_reconnect:, timeout: nil)
      loop do
        event = @parser.next_event(timeout: timeout)
        raise TimeoutError, "Timed out after #{timeout}s waiting for data from server" if event.nil?
        case event.type
        when :element
          log("<< #{event.element}") if @logger
          dispatch_incoming(event.element)
          return event.element
        when :eof
          handle_disconnect(::IOError.new("Connection closed by server"), allow_reconnect: allow_reconnect)
        when :error
          handle_disconnect(event.error, allow_reconnect: allow_reconnect)
        end
      end
    end

    def next_stanza_element
      loop do
        element = next_element(allow_reconnect: true)
        return element if %w[message presence iq].include?(element.name)
      end
    end

    # Matches an element against a wait name. Namespaced stream elements
    # ("stream:features", "stream:error") are matched by their effective
    # namespace so prefix binding never causes a silent miss.
    def element_matches?(element, name)
      case name
      when "stream:features"
        namespaced?(element, StreamNamespace) && element.name == "features"
      when "stream:error"
        namespaced?(element, StreamNamespace) && element.name == "error"
      else
        element.name == name
      end
    end

    def handle_disconnect(error, allow_reconnect:)
      mark_disconnected(error: error)
      raise(error || "Connection closed") unless allow_reconnect && @reconnect
      reconnect_with_backoff(error)
    end

    # Reconnects with exponential backoff. A re-entrancy flag prevents a
    # nested reconnect attempt (e.g. an IQ sent from a plugin's on_connect
    # hook failing while a reconnect is already in progress) from hitting a
    # recursive-mutex deadlock: the inner call raises immediately and the
    # outer loop simply retries.
    def reconnect_with_backoff(cause)
      raise Error, "Reconnect already in progress" if @reconnecting
      @reconnecting = true
      begin
        @reconnect_mutex.synchronize do
          attempts = 0
          interval = @reconnect_base_interval
          loop do
            attempts += 1
            if @reconnect_max_attempts && attempts > @reconnect_max_attempts
              raise(cause || "Reconnect attempts exceeded")
            end
            log("Reconnecting in #{interval}s")
            sleep interval
            begin
              connect_once
              start_ping
              log("Reconnected")
              return
            rescue StandardError => e
              log("Reconnect failed: #{e}")
              interval = [interval * 2, @reconnect_max_interval].min
            end
          end
        end
      ensure
        @reconnecting = false
      end
    end

    # Liveness: the ping thread sends XEP-0199 pings and verifies that *any*
    # server data arrives within a bounded window after each ping. If the
    # connection is silently dead (half-open TCP, dropped NAT state), the
    # next_element loop would otherwise block forever; the timeout check here
    # forces an error and triggers the reconnect path.
    def start_ping
      return unless @ping_interval && @ping_interval > 0
      @ping_thread = Thread.new do
        counter = 0
        loop do
          sleep_interval = ping_interval_seconds
          sleep sleep_interval
          break unless @connected
          counter += 1
          send_ping("ping_#{counter}")
          wait_for_liveness
        end
      rescue StandardError => e
        log("Ping error: #{e}")
      end
    end

    def ping_interval_seconds
      @ping_interval
    end

    # After a ping, the server must send *something* (the pong or any other
    # stanza) within half the ping interval. The parser thread records the
    # time of the last wire activity; if nothing arrived since the ping was
    # sent, the connection is assumed dead. Closing the socket (rather than
    # reconnecting here) makes the blocked parser read fail on the consumer
    # thread, so the reconnect runs there exactly like any other drop.
    def wait_for_liveness
      sent_at = last_incoming_time
      deadline = ping_interval_seconds / 2.0
      slept = 0.0
      step = 0.5
      while slept < deadline
        sleep step
        slept += step
        return if last_incoming_time > sent_at
      end
      log("No server data within #{deadline}s of ping; assuming dead connection")
      mark_disconnected(error: ::IOError.new("Ping timeout: no response from server"))
      @write_mutex.synchronize do
        @socket&.close
        @socket = nil
      end
    end

    def stop_ping
      @ping_thread&.kill
      @ping_thread = nil
    end

    def last_incoming_time
      @parser&.last_activity
    end

    def send_ping(id)
      iq = "<iq type='get' id='#{escape_attr(id)}' to='#{escape_attr(@domain)}'><ping xmlns='urn:xmpp:ping'/></iq>"
      send_raw(iq)
    end

    def send_raw(xml)
      xml = @plugin_manager.before_send(xml)
      log(">> #{xml}")
      @write_mutex.synchronize do
        raise Error, "Not connected" unless @socket
        @socket.write(xml)
      end
    end

    def parse_jid(jid)
      parts = jid.split("@", 2)
      raise ArgumentError, "JID must be in user@domain format" if parts.length != 2
      user = parts[0].split("/", 2).first
      domain = parts[1].split("/", 2).first
      [domain, user]
    end

    def log(message)
      return unless @logger
      @logger.call(message)
    end
  end
end
