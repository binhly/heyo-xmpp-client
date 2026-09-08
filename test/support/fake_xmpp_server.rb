require "socket"
require "openssl"
require "tmpdir"

# Scripted XMPP server for lifecycle integration tests. Listens on a real
# ephemeral TCP port so the client under test exercises its real transport,
# parser, TLS upgrade, SASL, bind, reconnect and ping code paths with zero
# stubbed internals.
#
# Each accepted connection is handed to the next registered script block:
#
#   server.on_connection do |conn|
#     conn.expect(/<stream:stream to='localhost'/)
#     conn.send(HEADER + FEATURES)
#     ...
#   end
#
# Conn#expect reads until the pattern matches (raising on timeout) and
# records every cleartext byte the client writes, so tests can assert
# secrets never hit the wire. Conn#start_tls_as_server upgrades the
# connection server-side after sending <proceed/>.
class FakeXmppServer
  XML_DECL = "<?xml version='1.0'?>"
  # The XML declaration may appear only once per parser lifetime; servers
  # omit it on stream restarts (post-SASL, post-STARTTLS the declaration
  # is allowed again only because the parser is recreated over TLS).
  HEADER = "<stream:stream from='localhost' id='fake001' version='1.0' " \
           "xml:lang='en' xmlns='jabber:client' " \
           "xmlns:stream='http://etherx.jabber.org/streams'>"

  def self.features(mechanisms: ["PLAIN"], starttls: false, bind: false)
    xml = +"<stream:features xmlns:stream='http://etherx.jabber.org/streams'>"
    xml << "<starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>" if starttls
    unless mechanisms.empty?
      xml << "<mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>"
      mechanisms.each { |m| xml << "<mechanism>#{m}</mechanism>" }
      xml << "</mechanisms>"
    end
    xml << "<bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'/>" if bind
    xml << "</stream:features>"
    xml
  end

  def self.bind_result(id, jid)
    "<iq type='result' id='#{id}'><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'>" \
      "<jid>#{jid}</jid></bind></iq>"
  end

  def self.iq_result(id)
    "<iq type='result' id='#{id}'/>"
  end

  def self.sasl_failure(child = "not-authorized")
    "<failure xmlns='urn:ietf:params:xml:ns:xmpp-sasl'><#{child}/></failure>"
  end

  attr_reader :host, :port

  def initialize
    @listener = TCPServer.new("127.0.0.1", 0)
    @host = "localhost"
    @port = @listener.addr[1]
    @scripts = []
    @script_queue = Queue.new
    @done = Queue.new
    @expected_done = 0
    @threads = []
    @accept_thread = nil
    @stopped = false
    @cert = nil
    @key = nil
    @ca_file = nil
  end

  def on_connection(&block)
    @scripts << block
    @expected_done += 1
    ensure_accept_thread
    @script_queue << block
    self
  end

  # Server-side self-signed cert, generated lazily; +ca_path+ is the PEM file
  # the client's SSL_CERT_FILE must point at.
  def cert
    generate_cert unless @cert
    @cert
  end

  def key
    generate_cert unless @key
    @key
  end

  def ca_path
    generate_cert unless @ca_file
    @ca_file
  end

  # Blocks until every registered script has run to completion (or raised).
  # Raises on timeout.
  def wait_for_scripts(timeout: 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    @expected_done.times do
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raise "Timed out waiting for #{remaining_scripts} server script(s) to finish" if remaining <= 0
      result = @done.pop(timeout: remaining)
      raise result if result.is_a?(ScriptFailure)
    end
  end

  def remaining_scripts
    @expected_done - @done.size
  end

  def stop
    @stopped = true
    @listener.close unless @listener.closed?
    @threads.each { |t| t.join(1) }
    @accept_thread&.join(1)
  rescue StandardError
    nil
  end

  ScriptFailure = Class.new(StandardError)

  # One scripted connection between the fake server and the real client.
  class Conn
    attr_reader :client_bytes

    def initialize(socket, server)
      @socket = socket
      @server = server
      @io = socket
      @buf = +""
      @client_bytes = +""
      @tls = false
    end

    def tls?
      @tls
    end

    def send(xml)
      @io.write(xml)
    end

    # Reads until +pattern+ (Regexp or String) matches the accumulated
    # client traffic. Returns the text from the start of the unread buffer
    # through the end of the match; keeps the unread remainder.
    def expect(pattern, timeout: 5)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        if (m = @buf.match(pattern))
          matched = @buf.slice(0...m.end(0))
          @buf = @buf.slice(m.end(0)..) || +""
          return matched
        end
        chunk = read_chunk(deadline)
        @client_bytes << chunk
        @buf << chunk
      end
    end

    # Wraps the raw socket in TLS as the server side of a STARTTLS upgrade.
    def start_tls_as_server
      ctx = OpenSSL::SSL::SSLContext.new
      ctx.cert = @server.cert
      ctx.key = @server.key
      ssl = OpenSSL::SSL::SSLSocket.new(@socket, ctx)
      ssl.sync_close = true
      ssl.accept
      @io = ssl
      @tls = true
    end

    def close
      @io.close
    rescue IOError
      nil
    end

    # Keeps the connection open (silently) until the client closes it or
    # +seconds+ elapse.
    def hold(seconds: 15)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      io = @io.respond_to?(:to_io) ? @io.to_io : @io
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        ready = IO.select([io], nil, nil, 0.1)
        return if ready
      end
    end

    # Consumes and discards client traffic until the client closes the
    # connection. EOF is the expected termination, not an error.
    def drain_until_close
      loop do
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
        read_chunk(deadline)
      end
    rescue EOFError
      nil
    end

    private

    def read_chunk(deadline)
      io = @io.respond_to?(:to_io) ? @io.to_io : @io
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raise "Timed out waiting for client data" if remaining <= 0
      ready = IO.select([io], nil, nil, remaining)
      raise "Timed out waiting for client data" unless ready
      chunk = @io.read_nonblock(4096, exception: false)
      chunk = @io.read_nonblock(4096, exception: false) if chunk == :wait_readable
      raise EOFError, "client closed connection" if chunk.nil? || chunk == :wait_readable
      chunk
    rescue EOFError, Errno::ECONNRESET, OpenSSL::SSL::SSLError => e
      raise EOFError, "client closed connection: #{e.class}"
    end
  end

  private

  def generate_cert
    return if @cert
    @key = OpenSSL::PKey::RSA.new(2048)
    cert = OpenSSL::X509::Certificate.new
    subject = OpenSSL::X509::Name.parse("CN=localhost")
    cert.subject = subject
    cert.issuer = subject
    cert.version = 2
    cert.not_before = Time.now - 60
    cert.not_after = Time.now + 3600
    cert.public_key = @key.public_key
    cert.serial = 1
    cert.sign(@key, OpenSSL::Digest.new("SHA256"))
    @cert = cert
    file = File.join(Dir.mktmpdir, "fake_xmpp_ca.pem")
    File.write(file, cert.to_pem)
    @ca_file = file
  end

  def ensure_accept_thread
    return if @accept_thread
    @script_queue = Queue.new
    @accept_thread = Thread.new do
      loop do
        socket = @listener.accept
        script = begin
          @script_queue.pop(true)
        rescue ThreadError
          nil
        end
        if script.nil?
          # No script registered for this connection; close politely.
          socket.close rescue nil
          next
        end
        thread = Thread.new(socket, script) do |sock, block|
          conn = Conn.new(sock, self)
          begin
            block.call(conn)
            @done << true
          rescue StandardError => e
            @done << ScriptFailure.new("server script failed: #{e.class}: #{e.message}")
          ensure
            conn.close
          end
        end
        @threads << thread
      end
    rescue IOError, Errno::EBADF
      nil
    end
  end
end
