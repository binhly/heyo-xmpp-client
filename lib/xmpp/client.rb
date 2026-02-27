require "socket"
require "openssl"
require "base64"
require "rexml/document"
require "thread"
require "securerandom"

require_relative "stream_parser"
require_relative "plugin_manager"
require_relative "xml_helpers"

module Xmpp
  class Client
    include Xmpp::XmlHelpers

    StreamHeader = %(<?xml version='1.0'?>\n<stream:stream to='%{domain}' xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' version='1.0'>)

    def initialize(jid:, password:, host: nil, port: 5222, use_tls: :starttls, resource: "ruby", logger: nil,
                   reconnect: true, reconnect_max_attempts: nil, reconnect_base_interval: 1,
                   reconnect_max_interval: 30, ping_interval: 60)
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
      @stop_ping = false
      @reconnect_mutex = Mutex.new
      @domain, @username = parse_jid(jid)
      @full_jid = nil
      @last_stream_features = nil
      @connected = false
      @plugin_manager = Xmpp::PluginManager.new(logger: @logger)
    end

    attr_reader :full_jid, :jid

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

    def request_iq(id:, xml:, allow_reconnect: true)
      send_raw(xml)
      wait_for_iq(id, allow_reconnect: allow_reconnect)
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
      send_raw(StreamHeader % { domain: @domain })
    end

    def start_tls
      send_raw("<starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>")
      wait_for_element(name: "proceed", allow_reconnect: false)
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
      ssl.connect
      @socket = ssl
      log("TLS negotiation successful")
    end

    def authenticate
      plugin_result = @plugin_manager.sasl_authenticate(self, @last_stream_features)
      return if plugin_result == true
      auth = Base64.strict_encode64("\0#{@username}\0#{@password}")
      response = sasl_authenticate(mechanism: "PLAIN", payload: auth)
      raise "SASL authentication failed" if response.name == "failure"
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
      cleanup_connection
      @socket = TCPSocket.new(@host || @domain, @port)
      log("Connected to #{@host || @domain}:#{@port}")

      if @use_tls == :always
        wrap_socket_with_tls
      end

      setup_parser
      open_stream
      features = wait_for_element(name: "stream:features", allow_reconnect: false)
      @last_stream_features = features
      @plugin_manager.on_stream_features(features)

      if @use_tls == :starttls && features_supports_starttls?(features)
        start_tls
        setup_parser
        open_stream
        features = wait_for_element(name: "stream:features", allow_reconnect: false)
        @last_stream_features = features
        @plugin_manager.on_stream_features(features)
      end
      authenticate
      open_stream
      features = wait_for_element(name: "stream:features", allow_reconnect: false)
      @last_stream_features = features
      @plugin_manager.on_stream_features(features)
      bind_resource
      start_session
      mark_connected
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
      features.elements.any? { |element| element.name == "starttls" }
    end

    def wait_for_element(name:, allow_reconnect:)
      names = Array(name)
      loop do
        element = next_element(allow_reconnect: allow_reconnect)
        return element if names.any? { |n| element.expanded_name == n || element.name == n }
      end
    end

    def wait_for_iq(id, allow_reconnect:)
      loop do
        element = next_element(allow_reconnect: allow_reconnect)
        next unless element.name == "iq"
        return element if element.attributes["id"] == id
      end
    end

    def next_element(allow_reconnect:)
      loop do
        event = @parser.next_event
        if event.type == :element
          log("<< #{event.element}") if @logger
          dispatch_incoming(event.element)
          return event.element
        end
        handle_disconnect(event.error, allow_reconnect: allow_reconnect)
      end
    end

    def next_stanza_element
      loop do
        element = next_element(allow_reconnect: true)
        return element if %w[message presence iq].include?(element.name)
      end
    end

    def handle_disconnect(error, allow_reconnect:)
      mark_disconnected(error: error)
      raise(error || "Connection closed") unless allow_reconnect && @reconnect
      reconnect_with_backoff(error)
    end

    def reconnect_with_backoff(cause)
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
    end

    def start_ping
      return unless @ping_interval && @ping_interval > 0
      @stop_ping = false
      @ping_thread = Thread.new do
        counter = 0
        loop do
          sleep @ping_interval
          break if @stop_ping
          counter += 1
          send_ping("ping_#{counter}")
        rescue StandardError => e
          log("Ping error: #{e}")
          break
        end
      end
    end

    def stop_ping
      @stop_ping = true
      @ping_thread&.kill
      @ping_thread = nil
    end

    def send_ping(id)
      iq = "<iq type='get' id='#{escape_attr(id)}' to='#{escape_attr(@domain)}'><ping xmlns='urn:xmpp:ping'/></iq>"
      send_raw(iq)
    end

    def send_raw(xml)
      xml = @plugin_manager.before_send(xml)
      log(">> #{xml}")
      @socket.write(xml)
    end

    def parse_jid(jid)
      parts = jid.split("@", 2)
      raise "JID must be in user@domain format" if parts.length != 2
      [parts[1], parts[0]]
    end

    def log(message)
      return unless @logger
      @logger.call(message)
    end
  end
end
